import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

// Spec 6.2's network proof over `iso.host/v1`: present only for a running
// brokered boot, bound to that boot, and closed to anything a client does not
// fully understand.

@Test func vmInspectCarriesTheBrokeredProofOfTheRunningBootOnly() throws {
  let f = try SupervisorFixture()
  defer { f.cleanup() }
  f.native.set { $0.brokered = true }
  let (instance, running) = try f.running(egress: .none)
  let proof = try #require(running.network)
  #expect(running.state == .running && proof.bootID == running.bootID)
  #expect(proof.externalNICCount == 0)
  // The proof survives the wire unchanged.
  let wire = running.wire
  guard case .object(let members) = wire, case .object(let network)? = members["network"] else {
    Issue.record("observation has no network object")
    return
  }
  #expect(network["transport"] == .string("brokered"))
  #expect(try VMObservation(wire: wire) == running)

  // A gate failure or a proof of another boot is not reported as running.
  f.native.inject("proof", .failed("gate refused"))
  let refused = try VMObservation(wire: f.call(.vmInspect(instance)).get())
  #expect(refused.state == .unhealthy && refused.network == nil && refused.bootID == nil)
  f.native.set { $0.proofBoot = try! BootID("stale-boot") }
  let stale = try VMObservation(wire: f.call(.vmInspect(instance)).get())
  #expect(stale.state == .unhealthy && stale.network == nil)
}

@Test func aVmnetObservationHasNoNetworkProof() throws {
  let f = try SupervisorFixture()
  defer { f.cleanup() }
  let (_, running) = try f.running()
  #expect(running.state == .running && running.network == nil)
  guard case .object(let members) = running.wire else { return }
  #expect(members["network"] == nil)
}

@Test func aClientRefusesANetworkProofItCannotTrust() throws {
  let f = try SupervisorFixture()
  defer { f.cleanup() }
  f.native.set { $0.brokered = true }
  let (_, running) = try f.running(egress: .none)
  guard case .object(var members) = running.wire,
    case .object(let network)? = members["network"]
  else {
    Issue.record("observation has no network object")
    return
  }
  func decodes(_ change: (inout [String: JSONValue]) -> Void) -> Bool {
    var altered = network
    change(&altered)
    members["network"] = .object(altered)
    return (try? VMObservation(wire: .object(members))) != nil
  }
  #expect(decodes { _ in })
  #expect(!decodes { $0["external_nic_count"] = .number(.unsigned(1)) })
  #expect(!decodes { $0["transport"] = .string("vmnet") })
  #expect(!decodes { $0["boot_id"] = .string("another-boot") })
  #expect(!decodes { $0["network_policy_digest"] = nil })
  #expect(!decodes { $0["channel_policy_digest"] = .string("not-a-digest") })
  #expect(!decodes { $0["gateway"] = .string("192.168.64.1") })
  // Nor a proof on a VM that is not running.
  members["network"] = .object(network)
  members["state"] = .string("stopped")
  #expect((try? VMObservation(wire: .object(members))) == nil)
}
