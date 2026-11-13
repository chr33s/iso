import Foundation
import IsoConfiguration
import IsoCore
import IsoHost

extension HostSupervisor {
  func accessOpen(_ request: AccessOpenRequest) throws(HostControlError) -> AccessGrant {
    // Epoch first: a delayed open from an old epoch never creates a session.
    guard request.expectedEpoch == epoch else {
      throw HostControlError(.sessionExpired, "daemon epoch changed")
    }
    let instance = try authoritative(request.instance)
    guard instance.lifecycle == .running, instance.activeOperation == nil else {
      throw HostControlError(.sessionExpired, "the instance is not running")
    }
    // A run's VM is attachable only while the run itself runs; a recovery
    // boot serves the worker's bounded export route alone.
    if let run = instance.runID, (try? runs.load(run))?.phase != .running {
      throw .unsupported("access to a run's VM outside its running phase")
    }
    guard instance.generation == request.expectedGeneration else {
      throw generationConflict(instance)
    }
    guard instance.policyHash == request.policyHash else {
      throw HostControlError(.sessionIdentityChanged, "policy changed")
    }
    // Fresh native proof: the live boot must be the recorded and expected one.
    let observed: NativeState
    do { observed = try native.observe(instance.instanceID, runtime: instance.runtimeID) } catch {
      throw HostControlError(.hostRuntimeUnqualified, "the VM could not be observed")
    }
    guard case .running(let boot, _, _) = observed, boot == instance.bootID,
      boot == request.expectedBoot
    else { throw HostControlError(.sessionIdentityChanged, "the VM boot changed") }
    let pin: String
    let user: GuestUser
    do {
      pin = try native.guestHostKey(instance.instanceID, runtime: instance.runtimeID)
      user = try native.guestUser(instance.instanceID, runtime: instance.runtimeID)
    } catch {
      throw HostControlError(.guestKeyChanged, "the guest host key is not pinned")
    }
    // Filtered egress: the worker's half of the composite proof, for this boot.
    let filtered: FilteredGrantPolicy?
    if decodeSpec(instance.spec)?.egress == .filtered {
      do {
        filtered = try native.filteredPolicy(instance.instanceID, runtime: instance.runtimeID)
      } catch {
        // The failing proof component (sanitized, bounded, nonsecret) so a
        // refusal is diagnosable from the client and the service log.
        let reason =
          switch error {
          case .failed(let text), .uncertain(let text), .unavailable(let text): text
          }
        diagnostics.warn("access.open refused for \(instance.instanceID): \(reason)")
        throw HostControlError(
          .sessionExpired, "FILTERED_EGRESS_NOT_READY on the host: " + reason)
      }
      guard let filtered, filtered.bootID == boot else {
        throw HostControlError(
          .sessionIdentityChanged, "the filtered boot policy is not for this boot")
      }
    } else {
      filtered = nil
    }
    let binding = AccessSessions.Binding(
      instance: instance.qualified, bootID: boot, policyHash: request.policyHash,
      generation: instance.generation, client: request.client,
      clientKey: request.clientKey.fingerprint, purpose: request.purpose, guestHostKey: pin,
      guestUser: user, clientPublicKey: request.clientKey, filteredPolicy: filtered)
    let grant = try sessions.open(
      request, binding: binding, vmExpiresAt: instance.expiresAt.map(WireTime.init(seconds:)))
    // Authorizing the session key is idempotent, so a replayed open repeats it safely.
    do {
      try native.authorizeClientKey(
        instance.instanceID, runtime: instance.runtimeID, key: request.clientKey)
    } catch {
      _ = try? sessions.close(session: request.session, bearer: request.bearer, epoch: epoch)
      throw HostControlError(.hostRuntimeUnqualified, "the client key could not be authorized")
    }
    // A stop or destroy admitted while this open ran has already revoked;
    // a grant registered after that must not survive it.
    guard grantStillValid(instance.instanceID, boot: boot) else {
      _ = try? sessions.close(session: request.session, bearer: request.bearer, epoch: epoch)
      throw HostControlError(.sessionExpired, "the VM is stopping or no longer running this boot")
    }
    return grant
  }

  /// Under the admission lock: the instance still runs this boot with no
  /// lifecycle operation in flight.
  func grantStillValid(_ id: InstanceID, boot: BootID) -> Bool {
    state.withLock { _ in
      guard let instance = try? store.loadInstance(id) else { return false }
      return instance.lifecycle == .running && instance.bootID == boot
        && instance.activeOperation == nil
    }
  }

  /// The guest endpoint for an admitted relay, chosen from current proof.
  package func relayEndpoint(_ binding: AccessSessions.Binding) throws(HostControlError)
    -> GuestEndpoint
  {
    guard let instance = try? store.loadInstance(binding.instance.instanceID),
      instance.lifecycle == .running, instance.bootID == binding.bootID
    else { throw HostControlError(.sessionExpired, "the VM is no longer running this boot") }
    do {
      guard
        case .running(let boot, _, _) = try native.observe(
          instance.instanceID, runtime: instance.runtimeID), boot == binding.bootID
      else { throw HostControlError(.sessionIdentityChanged, "the VM boot changed") }
      return try native.guestEndpoint(instance.instanceID, runtime: instance.runtimeID)
    } catch let error as HostControlError {
      throw error
    } catch {
      throw HostControlError(.sessionExpired, "the guest endpoint is unavailable")
    }
  }
}
