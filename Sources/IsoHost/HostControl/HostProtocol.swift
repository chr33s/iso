import CryptoKit
import Foundation
import IsoConfiguration
import IsoCore

/// `iso.host/v1` request and response envelopes (spec section 6). This is the
/// internal host-control protocol; it is separate from `iso.machine/v1`.
package enum HostProtocol {
  package static let v1 = "iso.host/v1"
  package static let supported = [v1]
}

/// Where a request arrived from. Assigned by the trusted transport adapter,
/// never read from a request field.
package enum HostTransportKind: String, Sendable, Equatable {
  case local
  case ssh
}

package enum HostMethod: String, CaseIterable, Sendable {
  case hello
  case hostCapabilities = "host.capabilities"
  case vmList = "vm.list"
  case vmInspect = "vm.inspect"
  case imageEnsure = "image.ensure"
  case vmCreate = "vm.create"
  case vmStart = "vm.start"
  case vmStop = "vm.stop"
  case vmDestroy = "vm.destroy"
  case operationGet = "operation.get"
  case operationCancel = "operation.cancel"
  case accessOpen = "access.open"
  case accessRenew = "access.renew"
  case accessClose = "access.close"
  case runCreate = "run.create"
  case runInspect = "run.inspect"
  case runComplete = "run.complete"
  case runResultsRecover = "run.results.recover"
  case runResultsAck = "run.results.ack"
  case runResultsDiscard = "run.results.discard"
  case runRetain = "run.retain"
  case artifactBegin = "artifact.begin"
  case artifactWrite = "artifact.write"
  case artifactCommit = "artifact.commit"
  case artifactRead = "artifact.read"
  case diagnosticsRead = "diagnostics.read"
  case vmResize = "vm.resize"
  case imageCommit = "image.commit"
  case vmRestore = "vm.restore"
  case macosComputerUseRead = "macos.computerUse.read"
  case macosComputerUseInput = "macos.computerUse.input"

  /// Durable mutations carry an envelope `operation_id` and go through the ledger.
  package var isDurableMutation: Bool {
    switch self {
    case .imageEnsure, .vmCreate, .vmStart, .vmStop, .vmDestroy, .runCreate, .runComplete,
      .runResultsRecover, .runResultsAck, .runResultsDiscard, .runRetain, .vmResize, .imageCommit,
      .vmRestore, .macosComputerUseInput:
      true
    default: false
    }
  }

  /// Local capabilities: dispatched by the local service, refused over SSH in
  /// remote v1 before any resource, image or secret work (spec 5.5, 6.3).
  package var isLocalOnly: Bool {
    switch self {
    case .vmResize, .imageCommit, .vmRestore, .macosComputerUseRead, .macosComputerUseInput: true
    default: false
    }
  }
}

/// The full identity of one VM. Mutations compare every field with the
/// authoritative record; display names and addresses never authorize.
package struct QualifiedInstance: Hashable, Sendable {
  package let hostID: HostID
  package let ownerID: OwnerID
  package let instanceID: InstanceID
  package let runtimeID: MachineName
  package let guestOS: GuestOS

  package init(
    hostID: HostID, ownerID: OwnerID, instanceID: InstanceID, runtimeID: MachineName,
    guestOS: GuestOS
  ) {
    self.hostID = hostID
    self.ownerID = ownerID
    self.instanceID = instanceID
    self.runtimeID = runtimeID
    self.guestOS = guestOS
  }

  package var wire: JSONValue {
    var builder = WireBuilder()
    builder.set("host_id", hostID)
    builder.set("owner_id", ownerID)
    builder.set("instance_id", instanceID)
    builder.set("runtime_id", runtimeID)
    builder.set("guest_os", guestOS.rawValue)
    return builder.value
  }

  package init(wire value: JSONValue, field: String) throws(HostControlError) {
    var reader = try WireObject(value, field: field)
    hostID = try reader.parsed("host_id", HostID.init)
    ownerID = try reader.parsed("owner_id", OwnerID.init)
    instanceID = try reader.parsed("instance_id", InstanceID.init)
    runtimeID = try reader.parsed("runtime_id", MachineName.init)
    guard let os = GuestOS(rawValue: try reader.string("guest_os")) else {
      throw .invalidRequest("invalid \(field).guest_os")
    }
    guestOS = os
    try reader.finish()
  }
}

/// A validated VM shape for `vm.create`. Client paths, command references,
/// grant bearers and resolved credentials have no field here (spec 5.2).
package struct VMSpec: Hashable, Sendable {
  package static let maxCPUs: UInt32 = 64
  package let name: InstanceName
  package let image: ImageName
  package let imageDigest: SHA256Hex?
  package let cpus: UInt32
  package let memoryMiB: UInt64
  package let diskGiB: UInt64
  package let guestOS: GuestOS
  package let egress: EgressMode
  package let policyHash: SHA256Hex

  package init(
    name: InstanceName, image: ImageName, imageDigest: SHA256Hex?, cpus: UInt32,
    memoryMiB: UInt64, diskGiB: UInt64, guestOS: GuestOS, egress: EgressMode, policyHash: SHA256Hex
  ) throws(ValidationError) {
    guard (1...Self.maxCPUs).contains(cpus) else { throw ValidationError("cpus out of range") }
    guard (256...(1 << 20)).contains(memoryMiB) else {
      throw ValidationError("memory_mib out of range")
    }
    guard (1...4_096).contains(diskGiB) else { throw ValidationError("disk_gib out of range") }
    self.name = name
    self.image = image
    self.imageDigest = imageDigest
    self.cpus = cpus
    self.memoryMiB = memoryMiB
    self.diskGiB = diskGiB
    self.guestOS = guestOS
    self.egress = egress
    self.policyHash = policyHash
  }

  /// The policy identity of this shape: image, resources, guest and egress
  /// (not the display name). Workers recompute it and refuse a mismatch.
  package var computedPolicyHash: SHA256Hex {
    Self.policyHash(
      image: image, imageDigest: imageDigest, cpus: cpus, memoryMiB: memoryMiB, diskGiB: diskGiB,
      guestOS: guestOS, egress: egress)
  }

  package static func policyHash(
    image: ImageName, imageDigest: SHA256Hex?, cpus: UInt32, memoryMiB: UInt64, diskGiB: UInt64,
    guestOS: GuestOS, egress: EgressMode
  ) -> SHA256Hex {
    var builder = WireBuilder()
    builder.set("image", image)
    builder.setIfPresent("image_digest", imageDigest)
    builder.set("cpus", UInt64(cpus))
    builder.set("memory_mib", memoryMiB)
    builder.set("disk_gib", diskGiB)
    builder.set("guest_os", guestOS.rawValue)
    builder.set("egress", egress.rawValue)
    return HostWire.sha256(HostWire.canonical(builder.value))
  }

  /// A spec whose policy hash is computed rather than supplied.
  package static func make(
    name: InstanceName, image: ImageName, imageDigest: SHA256Hex?, cpus: UInt32,
    memoryMiB: UInt64, diskGiB: UInt64, guestOS: GuestOS, egress: EgressMode
  ) throws(ValidationError) -> VMSpec {
    try VMSpec(
      name: name, image: image, imageDigest: imageDigest, cpus: cpus, memoryMiB: memoryMiB,
      diskGiB: diskGiB, guestOS: guestOS, egress: egress,
      policyHash: policyHash(
        image: image, imageDigest: imageDigest, cpus: cpus, memoryMiB: memoryMiB,
        diskGiB: diskGiB, guestOS: guestOS, egress: egress))
  }

  package var wire: JSONValue {
    var builder = WireBuilder()
    builder.set("name", name)
    builder.set("image", image)
    builder.setIfPresent("image_digest", imageDigest)
    builder.set("cpus", UInt64(cpus))
    builder.set("memory_mib", memoryMiB)
    builder.set("disk_gib", diskGiB)
    builder.set("guest_os", guestOS.rawValue)
    builder.set("egress", egress.rawValue)
    builder.set("policy_hash", policyHash)
    return builder.value
  }

  package init(reading reader: inout WireObject) throws(HostControlError) {
    let name = try reader.parsed("name", InstanceName.init)
    let image = try reader.parsed("image", ImageName.init)
    let digest = try reader.optionalParsed("image_digest", SHA256Hex.init)
    let cpus = try reader.unsigned("cpus", as: UInt32.self)
    let memory = try reader.unsigned("memory_mib", as: UInt64.self)
    let disk = try reader.unsigned("disk_gib", as: UInt64.self)
    guard let os = GuestOS(rawValue: try reader.string("guest_os")),
      let egress = EgressMode(rawValue: try reader.string("egress"))
    else { throw .invalidRequest("invalid params.guest_os or params.egress") }
    let policy = try reader.parsed("policy_hash", SHA256Hex.init)
    do {
      try self.init(
        name: name, image: image, imageDigest: digest, cpus: cpus, memoryMiB: memory,
        diskGiB: disk, guestOS: os, egress: egress, policyHash: policy)
    } catch { throw .invalidRequest("params: \(error.message)") }
  }
}

/// `image.ensure`: build (or confirm) a named image on the worker from the
/// worker's own build context and profile definitions. No client path,
/// command or file travels; profiles are names the worker resolves.
package struct ImageRequest: Sendable, Equatable {
  package static let maxProfiles = 16
  package let image: ImageName
  package let guestOS: GuestOS
  package let profiles: [String]
  package let guestUser: GuestUser
  package let rebuild: Bool

  package init(
    image: ImageName, guestOS: GuestOS, profiles: [String], guestUser: GuestUser, rebuild: Bool
  ) throws(ValidationError) {
    guard profiles.count <= Self.maxProfiles else { throw ValidationError("too many profiles") }
    for name in profiles {
      guard (1...64).contains(name.utf8.count), name.unicodeScalars.allSatisfy(isSafeNameCharacter)
      else { throw ValidationError("invalid profile name \(debugQuoted(name))") }
    }
    self.image = image
    self.guestOS = guestOS
    self.profiles = profiles
    self.guestUser = guestUser
    self.rebuild = rebuild
  }
}

/// A stopped-VM maintenance change. Only the local service dispatches it.
package enum Maintenance: Sendable, Equatable {
  case resize(cpus: UInt32?, memoryMiB: UInt64?, diskGiB: UInt64?)
  case commit(ImageName)
  case restore(ImageName)

  package var method: HostMethod {
    switch self {
    case .resize: .vmResize
    case .commit: .imageCommit
    case .restore: .vmRestore
    }
  }

  /// At least one bounded field; disk only grows (checked natively).
  package static func validatedResize(cpus: UInt32?, memoryMiB: UInt64?, diskGiB: UInt64?)
    throws(HostControlError) -> Maintenance
  {
    guard cpus != nil || memoryMiB != nil || diskGiB != nil else {
      throw .invalidRequest("resize needs cpus, memory_mib or disk_gib")
    }
    if let cpus, !(1...UInt32(UInt8.max)).contains(cpus) {
      throw .invalidRequest("cpus out of range")
    }
    if let memoryMiB, !(256...UInt64(UInt32.max)).contains(memoryMiB) {
      throw .invalidRequest("memory_mib out of range")
    }
    if let diskGiB, !(1...4_096).contains(diskGiB) {
      throw .invalidRequest("disk_gib out of range")
    }
    return .resize(cpus: cpus, memoryMiB: memoryMiB, diskGiB: diskGiB)
  }
}

/// Host-owned retention requested through `run.retain`.
package enum RetentionMode: String, Sendable, CaseIterable, Codable {
  /// Keep the run's VM running (no controlling session needed) until a
  /// finite deadline that never passes the VM's own hard deadline.
  case live
  /// Keep the stopped disk and staged results longer, up to a fixed cap.
  case stopped
}

/// Purpose a live access session is admitted for.
package enum AccessPurpose: String, Sendable, CaseIterable {
  case ssh
  case editor
  case forward
}

/// A client-generated access bearer: 32–64 random bytes as lowercase hex.
/// Only its SHA-256 is retained by the worker. Never logged or printed.
package struct AccessBearer: Sendable, Equatable {
  package let rawValue: String

  package init(_ value: String) throws(ValidationError) {
    let bytes = Array(value.utf8)
    guard (64...128).contains(bytes.count), bytes.count % 2 == 0,
      bytes.allSatisfy({
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
          || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
      })
    else { throw ValidationError("access bearer must be 64-128 lowercase hex characters") }
    rawValue = value
  }

  /// 256 bits from the system CSPRNG.
  package static func generate() -> AccessBearer {
    var bytes = [UInt8](repeating: 0, count: 32)
    arc4random_buf(&bytes, bytes.count)
    return AccessBearer(unchecked: SHA256Hex(digest: bytes).rawValue)
  }

  private init(unchecked value: String) { rawValue = value }

  package var verifier: SHA256Hex { HostWire.sha256(Array(rawValue.utf8)) }
}

/// A client's ed25519 SSH public key, authorized in the guest for one
/// session. Only the key travels; the private key never leaves the client.
package struct ClientPublicKey: Sendable, Equatable {
  package let key: HostPublicKey

  package init(_ text: String) throws(ValidationError) {
    guard text.utf8.count <= 512 else { throw ValidationError("public key is too long") }
    do { key = try HostPublicKey(parsing: text) } catch {
      throw ValidationError("client key must be one ssh-ed25519 public key")
    }
  }

  /// `ssh-ed25519 <base64>`, without any comment.
  package var line: String { "ssh-ed25519 " + key.base64 }
  /// The binding identity compared on every use of a grant.
  package var fingerprint: SHA256Hex { SHA256Hex(digest: SHA256.hash(data: key.blob)) }
}

/// Typed request parameters, one case per method.
package enum HostRequestBody: Sendable, Equatable {
  case hello(protocols: [String], clientBuild: String)
  /// What this host can do now and the evidence behind it; params are `{}`.
  case hostCapabilities
  case vmList(cursor: InstanceID?, limit: UInt32)
  case vmInspect(QualifiedInstance)
  case imageEnsure(ImageRequest)
  case vmCreate(VMSpec)
  case vmStart(
    QualifiedInstance, expectedGeneration: UInt64, ttlSeconds: UInt64?, policy: SHA256Hex)
  case vmStop(QualifiedInstance, expectedGeneration: UInt64)
  case vmDestroy(QualifiedInstance, expectedGeneration: UInt64)
  case operationGet(HostOperationID)
  case operationCancel(target: HostOperationID)
  case accessOpen(AccessOpenRequest)
  case accessRenew(
    session: SessionID, bearer: AccessBearer, epoch: DaemonEpoch, boot: BootID, policy: SHA256Hex)
  case accessClose(session: SessionID, bearer: AccessBearer, epoch: DaemonEpoch)
  case runCreate(run: RunID, spec: VMSpec, outputLimitBytes: UInt64, ttlSeconds: UInt64)
  case runInspect(RunID)
  case runComplete(run: RunID, expectedGeneration: UInt64, exitStatus: Int32?)
  case runResultsRecover(run: RunID, expectedGeneration: UInt64)
  case runResultsAck(run: RunID, expectedGeneration: UInt64, digest: SHA256Hex, stage: StageID)
  case runResultsDiscard(run: RunID, expectedGeneration: UInt64)
  case runRetain(run: RunID, expectedGeneration: UInt64, mode: RetentionMode, seconds: UInt64)
  case artifactBegin(kind: ArtifactKind, size: UInt64, digest: SHA256Hex)
  case artifactWrite(handle: ArtifactHandle, offset: UInt64, bytes: [UInt8])
  case artifactCommit(handle: ArtifactHandle)
  case artifactRead(handle: ArtifactHandle, offset: UInt64, length: UInt32)
  case diagnosticsRead(operation: HostOperationID, limit: UInt32)
  /// Local maintenance of a stopped service-managed VM (resize, commit, restore).
  case maintenance(QualifiedInstance, expectedGeneration: UInt64, Maintenance)
  /// macOS computer use: a local capability this service does not dispatch.
  case localCapability(HostMethod, QualifiedInstance, expectedGeneration: UInt64)

  package static let maxArtifactChunk = 32 << 10

  package var method: HostMethod {
    switch self {
    case .hello: .hello
    case .hostCapabilities: .hostCapabilities
    case .vmList: .vmList
    case .vmInspect: .vmInspect
    case .imageEnsure: .imageEnsure
    case .vmCreate: .vmCreate
    case .vmStart: .vmStart
    case .vmStop: .vmStop
    case .vmDestroy: .vmDestroy
    case .operationGet: .operationGet
    case .operationCancel: .operationCancel
    case .accessOpen: .accessOpen
    case .accessRenew: .accessRenew
    case .accessClose: .accessClose
    case .runCreate: .runCreate
    case .runInspect: .runInspect
    case .runComplete: .runComplete
    case .runResultsRecover: .runResultsRecover
    case .runResultsAck: .runResultsAck
    case .runResultsDiscard: .runResultsDiscard
    case .runRetain: .runRetain
    case .artifactBegin: .artifactBegin
    case .artifactWrite: .artifactWrite
    case .artifactCommit: .artifactCommit
    case .artifactRead: .artifactRead
    case .diagnosticsRead: .diagnosticsRead
    case .localCapability(let method, _, _): method
    case .maintenance(_, _, let change): change.method
    }
  }

  /// The instance a mutation targets, when it names one.
  package var target: QualifiedInstance? {
    switch self {
    case .vmInspect(let instance), .vmStart(let instance, _, _, _), .vmStop(let instance, _),
      .vmDestroy(let instance, _), .localCapability(_, let instance, _),
      .maintenance(let instance, _, _):
      instance
    case .accessOpen(let open): open.instance
    default: nil
    }
  }

  package var params: JSONValue {
    var b = WireBuilder()
    switch self {
    case .hello(let protocols, let build):
      b.set("protocols", .array(protocols.map { .string($0) }))
      b.set("client_build", build)
    case .hostCapabilities:
      break
    case .vmList(let cursor, let limit):
      b.setIfPresent("cursor", cursor)
      b.set("limit", UInt64(limit))
    case .vmInspect(let instance):
      b.set("instance", instance.wire)
    case .imageEnsure(let request):
      b.set("image", request.image)
      b.set("guest_os", request.guestOS.rawValue)
      b.set("profiles", .array(request.profiles.map { .string($0) }))
      b.set("guest_user", request.guestUser)
      b.set("rebuild", request.rebuild)
    case .vmCreate(let spec):
      return spec.wire
    case .vmStart(let instance, let generation, let ttl, let policy):
      b.set("instance", instance.wire)
      b.set("expected_generation", generation)
      b.setIfPresent("ttl_seconds", ttl)
      b.set("policy_hash", policy)
    case .vmStop(let instance, let generation), .vmDestroy(let instance, let generation),
      .localCapability(_, let instance, let generation):
      b.set("instance", instance.wire)
      b.set("expected_generation", generation)
    case .maintenance(let instance, let generation, let change):
      b.set("instance", instance.wire)
      b.set("expected_generation", generation)
      switch change {
      case .resize(let cpus, let memory, let disk):
        b.setIfPresent("cpus", cpus.map(UInt64.init))
        b.setIfPresent("memory_mib", memory)
        b.setIfPresent("disk_gib", disk)
      case .commit(let image), .restore(let image):
        b.set("image", image)
      }
    case .operationGet(let operation):
      b.set("operation_id", operation)
    case .operationCancel(let target):
      b.set("target_operation_id", target)
    case .accessOpen(let open):
      return open.wire
    case .accessRenew(let session, let bearer, let epoch, let boot, let policy):
      b.set("session_id", session)
      b.set("bearer", bearer.rawValue)
      b.set("expected_epoch", epoch)
      b.set("expected_boot", boot)
      b.set("policy_hash", policy)
    case .accessClose(let session, let bearer, let epoch):
      b.set("session_id", session)
      b.set("bearer", bearer.rawValue)
      b.set("expected_epoch", epoch)
    case .runCreate(let run, let spec, let output, let ttl):
      b.set("run_id", run)
      b.set("spec", spec.wire)
      b.set("output_limit_bytes", output)
      b.set("ttl_seconds", ttl)
    case .runInspect(let run):
      b.set("run_id", run)
    case .runComplete(let run, let generation, let status):
      b.set("run_id", run)
      b.set("expected_generation", generation)
      if let status { b.set("exit_status", .number(.integer(Int64(status)))) }
    case .runResultsRecover(let run, let generation), .runResultsDiscard(let run, let generation):
      b.set("run_id", run)
      b.set("expected_generation", generation)
    case .runRetain(let run, let generation, let mode, let seconds):
      b.set("run_id", run)
      b.set("expected_generation", generation)
      b.set("mode", mode.rawValue)
      b.set("seconds", seconds)
    case .runResultsAck(let run, let generation, let digest, let stage):
      b.set("run_id", run)
      b.set("expected_generation", generation)
      b.set("digest", digest)
      b.set("stage_id", stage)
      b.set("stage_complete", true)
    case .artifactBegin(let kind, let size, let digest):
      b.set("kind", kind.rawValue)
      b.set("size", size)
      b.set("digest", digest)
    case .artifactWrite(let handle, let offset, let bytes):
      b.set("handle", handle)
      b.set("offset", offset)
      b.set("data", Data(bytes).base64EncodedString())
    case .artifactCommit(let handle):
      b.set("handle", handle)
    case .artifactRead(let handle, let offset, let length):
      b.set("handle", handle)
      b.set("offset", offset)
      b.set("length", UInt64(length))
    case .diagnosticsRead(let operation, let limit):
      b.set("operation_id", operation)
      b.set("limit", UInt64(limit))
    }
    return b.value
  }

  package init(method: HostMethod, params value: JSONValue) throws(HostControlError) {
    var r = try WireObject(value, field: "params")
    switch method {
    case .hello:
      let protocols = try r.array("protocols")
      guard (1...8).contains(protocols.count) else {
        throw .invalidRequest("params.protocols must list 1-8 versions")
      }
      var names: [String] = []
      for item in protocols { names.append(try WireObject.string(item, field: "params.protocols")) }
      let build = try r.string("client_build")
      guard build.utf8.count <= 128 else { throw .invalidRequest("params.client_build too long") }
      self = .hello(protocols: names, clientBuild: build)
    case .hostCapabilities:
      self = .hostCapabilities
    case .vmList:
      let cursor = try r.optionalParsed("cursor", InstanceID.init)
      let limit = try r.unsigned("limit", as: UInt32.self)
      guard (1...200).contains(limit) else { throw .invalidRequest("params.limit must be 1-200") }
      self = .vmList(cursor: cursor, limit: limit)
    case .vmInspect:
      self = .vmInspect(
        try QualifiedInstance(wire: try r.required("instance"), field: "params.instance"))
    case .imageEnsure:
      let image = try r.parsed("image", ImageName.init)
      guard let os = GuestOS(rawValue: try r.string("guest_os")) else {
        throw .invalidRequest("invalid params.guest_os")
      }
      var profiles: [String] = []
      for item in try r.array("profiles") {
        profiles.append(try WireObject.string(item, field: "params.profiles"))
      }
      let user = try r.parsed("guest_user", GuestUser.init)
      let rebuild = try r.bool("rebuild")
      do {
        self = .imageEnsure(
          try ImageRequest(
            image: image, guestOS: os, profiles: profiles, guestUser: user, rebuild: rebuild))
      } catch { throw .invalidRequest("params: \(error.message)") }
    case .vmCreate:
      self = .vmCreate(try VMSpec(reading: &r))
    case .vmStart:
      let instance = try QualifiedInstance(
        wire: try r.required("instance"), field: "params.instance")
      let generation = try r.unsigned("expected_generation", as: UInt64.self)
      let ttl = try r.optionalUnsigned("ttl_seconds", as: UInt64.self)
      let policy = try r.parsed("policy_hash", SHA256Hex.init)
      self = .vmStart(instance, expectedGeneration: generation, ttlSeconds: ttl, policy: policy)
    case .vmStop, .vmDestroy, .vmResize, .imageCommit, .vmRestore, .macosComputerUseRead,
      .macosComputerUseInput:
      let instance = try QualifiedInstance(
        wire: try r.required("instance"), field: "params.instance")
      let generation = try r.unsigned("expected_generation", as: UInt64.self)
      switch method {
      case .vmStop: self = .vmStop(instance, expectedGeneration: generation)
      case .vmDestroy: self = .vmDestroy(instance, expectedGeneration: generation)
      case .vmResize:
        let change = try Maintenance.validatedResize(
          cpus: try r.optionalUnsigned("cpus", as: UInt32.self),
          memoryMiB: try r.optionalUnsigned("memory_mib", as: UInt64.self),
          diskGiB: try r.optionalUnsigned("disk_gib", as: UInt64.self))
        self = .maintenance(instance, expectedGeneration: generation, change)
      case .imageCommit:
        self = .maintenance(
          instance, expectedGeneration: generation, .commit(try r.parsed("image", ImageName.init)))
      case .vmRestore:
        self = .maintenance(
          instance, expectedGeneration: generation, .restore(try r.parsed("image", ImageName.init)))
      default: self = .localCapability(method, instance, expectedGeneration: generation)
      }
    case .operationGet:
      self = .operationGet(try r.parsed("operation_id", HostOperationID.init))
    case .operationCancel:
      self = .operationCancel(target: try r.parsed("target_operation_id", HostOperationID.init))
    case .accessOpen:
      self = .accessOpen(try AccessOpenRequest(reading: &r))
    case .accessRenew:
      self = .accessRenew(
        session: try r.parsed("session_id", SessionID.init),
        bearer: try r.parsed("bearer", AccessBearer.init),
        epoch: try r.parsed("expected_epoch", DaemonEpoch.init),
        boot: try r.parsed("expected_boot", BootID.init),
        policy: try r.parsed("policy_hash", SHA256Hex.init))
    case .accessClose:
      self = .accessClose(
        session: try r.parsed("session_id", SessionID.init),
        bearer: try r.parsed("bearer", AccessBearer.init),
        epoch: try r.parsed("expected_epoch", DaemonEpoch.init))
    case .runCreate:
      let run = try r.parsed("run_id", RunID.init)
      var specReader = try r.object("spec")
      let spec = try VMSpec(reading: &specReader)
      try specReader.finish()
      self = .runCreate(
        run: run, spec: spec, outputLimitBytes: try r.unsigned("output_limit_bytes"),
        ttlSeconds: try r.unsigned("ttl_seconds"))
    case .runInspect:
      self = .runInspect(try r.parsed("run_id", RunID.init))
    case .runComplete:
      let run = try r.parsed("run_id", RunID.init)
      let generation = try r.unsigned("expected_generation", as: UInt64.self)
      var status: Int32?
      if let raw = r.raw("exit_status") {
        guard case .number(.integer(let value)) = raw, let exact = Int32(exactly: value) else {
          throw .invalidRequest("params.exit_status must be an integer")
        }
        status = exact
      }
      self = .runComplete(run: run, expectedGeneration: generation, exitStatus: status)
    case .runResultsRecover:
      self = .runResultsRecover(
        run: try r.parsed("run_id", RunID.init),
        expectedGeneration: try r.unsigned("expected_generation"))
    case .runResultsDiscard:
      self = .runResultsDiscard(
        run: try r.parsed("run_id", RunID.init),
        expectedGeneration: try r.unsigned("expected_generation"))
    case .runRetain:
      let run = try r.parsed("run_id", RunID.init)
      let generation = try r.unsigned("expected_generation", as: UInt64.self)
      guard let mode = RetentionMode(rawValue: try r.string("mode")) else {
        throw .invalidRequest("params.mode must be live or stopped")
      }
      let seconds = try r.unsigned("seconds", as: UInt64.self)
      guard seconds > 0, seconds <= RunStore.maxRetentionSeconds(mode) else {
        throw .invalidRequest(
          "params.seconds must be 1-\(RunStore.maxRetentionSeconds(mode)) for \(mode.rawValue)")
      }
      self = .runRetain(run: run, expectedGeneration: generation, mode: mode, seconds: seconds)
    case .runResultsAck:
      let run = try r.parsed("run_id", RunID.init)
      let generation = try r.unsigned("expected_generation", as: UInt64.self)
      let digest = try r.parsed("digest", SHA256Hex.init)
      let stage = try r.parsed("stage_id", StageID.init)
      guard try r.bool("stage_complete") else {
        throw .invalidRequest("params.stage_complete must be true")
      }
      self = .runResultsAck(run: run, expectedGeneration: generation, digest: digest, stage: stage)
    case .artifactBegin:
      guard let kind = ArtifactKind(rawValue: try r.string("kind")) else {
        throw .invalidRequest("invalid params.kind")
      }
      self = .artifactBegin(
        kind: kind, size: try r.unsigned("size"), digest: try r.parsed("digest", SHA256Hex.init))
    case .artifactWrite:
      let handle = try r.parsed("handle", ArtifactHandle.init)
      let offset = try r.unsigned("offset", as: UInt64.self)
      guard let data = Data(base64Encoded: try r.string("data")),
        data.count <= Self.maxArtifactChunk
      else { throw .invalidRequest("params.data must be base64, at most 32 KiB") }
      self = .artifactWrite(handle: handle, offset: offset, bytes: Array(data))
    case .artifactCommit:
      self = .artifactCommit(handle: try r.parsed("handle", ArtifactHandle.init))
    case .artifactRead:
      let handle = try r.parsed("handle", ArtifactHandle.init)
      let offset = try r.unsigned("offset", as: UInt64.self)
      let length = try r.unsigned("length", as: UInt32.self)
      guard (1...UInt32(Self.maxArtifactChunk)).contains(length) else {
        throw .invalidRequest("params.length must be 1-32768")
      }
      self = .artifactRead(handle: handle, offset: offset, length: length)
    case .diagnosticsRead:
      let operation = try r.parsed("operation_id", HostOperationID.init)
      let limit = try r.unsigned("limit", as: UInt32.self)
      guard (1...256).contains(limit) else { throw .invalidRequest("params.limit must be 1-256") }
      self = .diagnosticsRead(operation: operation, limit: limit)
    }
    try r.finish()
  }
}

package struct AccessOpenRequest: Sendable, Equatable {
  package let instance: QualifiedInstance
  package let expectedEpoch: DaemonEpoch
  package let expectedBoot: BootID
  package let expectedGeneration: UInt64
  package let policyHash: SHA256Hex
  package let session: SessionID
  package let client: ClientLabel
  package let clientKey: ClientPublicKey
  package let purpose: AccessPurpose
  package let bearer: AccessBearer

  package init(
    instance: QualifiedInstance, expectedEpoch: DaemonEpoch, expectedBoot: BootID,
    expectedGeneration: UInt64, policyHash: SHA256Hex, session: SessionID, client: ClientLabel,
    clientKey: ClientPublicKey, purpose: AccessPurpose, bearer: AccessBearer
  ) {
    self.instance = instance
    self.expectedEpoch = expectedEpoch
    self.expectedBoot = expectedBoot
    self.expectedGeneration = expectedGeneration
    self.policyHash = policyHash
    self.session = session
    self.client = client
    self.clientKey = clientKey
    self.purpose = purpose
    self.bearer = bearer
  }

  var wire: JSONValue {
    var b = WireBuilder()
    b.set("instance", instance.wire)
    b.set("expected_epoch", expectedEpoch)
    b.set("expected_boot", expectedBoot)
    b.set("expected_generation", expectedGeneration)
    b.set("policy_hash", policyHash)
    b.set("session_id", session)
    b.set("client", client)
    b.set("client_public_key", clientKey.line)
    b.set("purpose", purpose.rawValue)
    b.set("bearer", bearer.rawValue)
    return b.value
  }

  init(reading r: inout WireObject) throws(HostControlError) {
    instance = try QualifiedInstance(wire: try r.required("instance"), field: "params.instance")
    expectedEpoch = try r.parsed("expected_epoch", DaemonEpoch.init)
    expectedBoot = try r.parsed("expected_boot", BootID.init)
    expectedGeneration = try r.unsigned("expected_generation")
    policyHash = try r.parsed("policy_hash", SHA256Hex.init)
    session = try r.parsed("session_id", SessionID.init)
    client = try r.parsed("client", ClientLabel.init)
    clientKey = try r.parsed("client_public_key", ClientPublicKey.init)
    guard let purpose = AccessPurpose(rawValue: try r.string("purpose")) else {
      throw .invalidRequest("invalid params.purpose")
    }
    self.purpose = purpose
    bearer = try r.parsed("bearer", AccessBearer.init)
  }
}

/// One decoded request. `hostID`/`ownerID` are absent only on `hello`.
package struct HostRequest: Sendable, Equatable {
  package let requestID: RequestID
  package let hostID: HostID?
  package let ownerID: OwnerID?
  package let operationID: HostOperationID?
  package let body: HostRequestBody

  package init(
    requestID: RequestID = .generate(), hostID: HostID?, ownerID: OwnerID?,
    operationID: HostOperationID? = nil, body: HostRequestBody
  ) {
    self.requestID = requestID
    self.hostID = hostID
    self.ownerID = ownerID
    self.operationID = operationID
    self.body = body
  }

  package var wire: JSONValue {
    var b = WireBuilder()
    b.set("protocol", HostProtocol.v1)
    b.set("request_id", requestID)
    b.setIfPresent("host_id", hostID)
    b.setIfPresent("owner_id", ownerID)
    b.set("method", body.method.rawValue)
    b.setIfPresent("operation_id", operationID)
    b.set("params", body.params)
    return b.value
  }

  package var frame: [UInt8] { HostWire.frame(wire) }

  /// The canonical identity a durable operation is deduplicated by: method,
  /// target and normalized typed params. Excludes request id and transport.
  package var digest: SHA256Hex {
    var b = WireBuilder()
    b.set("method", body.method.rawValue)
    b.set("params", body.params)
    return HostWire.sha256(HostWire.canonical(b.value))
  }

  /// Why a frame failed before a valid request id was known: the stream is
  /// closed without a correlated reply (spec 6.1).
  package enum DecodeFailure: Error, Sendable, Equatable {
    case uncorrelated(HostControlError)
    case correlated(RequestID, HostControlError)
  }

  package static func decode(frame: [UInt8]) throws(DecodeFailure) -> HostRequest {
    let value: JSONValue
    do { value = try HostWire.parse(frame, limits: HostWire.requestLimits) } catch {
      throw .uncorrelated(error)
    }
    guard case .object(let members) = value,
      case .string(let rawID) = members["request_id"], let requestID = try? RequestID(rawID)
    else { throw .uncorrelated(.invalidRequest("missing or invalid request_id")) }
    do {
      return try decode(value, requestID: requestID)
    } catch {
      throw .correlated(requestID, error)
    }
  }

  private static func decode(_ value: JSONValue, requestID: RequestID) throws(HostControlError)
    -> HostRequest
  {
    var r = try WireObject(value, field: "")
    _ = r.raw("request_id")
    let version = try r.string("protocol")
    guard HostProtocol.supported.contains(version) else {
      throw HostControlError(.hostProtocolIncompatible, "unsupported protocol version")
    }
    guard let method = HostMethod(rawValue: try r.string("method")) else {
      throw .invalidRequest("unknown method")
    }
    let hostID = try r.optionalParsed("host_id", HostID.init)
    let ownerID = try r.optionalParsed("owner_id", OwnerID.init)
    let operationID = try r.optionalParsed("operation_id", HostOperationID.init)
    if method != .hello, hostID == nil || ownerID == nil {
      throw .invalidRequest("host_id and owner_id are required")
    }
    if method.isDurableMutation != (operationID != nil) {
      throw .invalidRequest(
        method.isDurableMutation ? "operation_id is required" : "operation_id is not accepted")
    }
    let body = try HostRequestBody(method: method, params: try r.required("params"))
    try r.finish()
    return HostRequest(
      requestID: requestID, hostID: hostID, ownerID: ownerID, operationID: operationID, body: body)
  }
}

/// One response. Every response names the host, owner and daemon epoch so the
/// client can validate it before using the payload.
package struct HostResponse: Sendable, Equatable {
  package let requestID: RequestID
  package let hostID: HostID
  package let ownerID: OwnerID
  package let epoch: DaemonEpoch
  package let outcome: Result<JSONValue, HostControlError>

  package init(
    requestID: RequestID, hostID: HostID, ownerID: OwnerID, epoch: DaemonEpoch,
    outcome: Result<JSONValue, HostControlError>
  ) {
    self.requestID = requestID
    self.hostID = hostID
    self.ownerID = ownerID
    self.epoch = epoch
    self.outcome = outcome
  }

  package var wire: JSONValue {
    var b = WireBuilder()
    b.set("protocol", HostProtocol.v1)
    b.set("request_id", requestID)
    b.set("host_id", hostID)
    b.set("owner_id", ownerID)
    b.set("daemon_epoch", epoch)
    switch outcome {
    case .success(let result): b.set("result", result)
    case .failure(let error): b.set("error", error.wire)
    }
    return b.value
  }

  package var frame: [UInt8] { HostWire.frame(wire) }

  package static func decode(frame: [UInt8]) throws(HostControlError) -> HostResponse {
    let value = try HostWire.parse(frame, limits: HostWire.responseLimits)
    var r = try WireObject(value, field: "")
    guard try r.string("protocol") == HostProtocol.v1 else {
      throw HostControlError(.hostProtocolIncompatible, "response protocol mismatch")
    }
    let requestID = try r.parsed("request_id", RequestID.init)
    let hostID = try r.parsed("host_id", HostID.init)
    let ownerID = try r.parsed("owner_id", OwnerID.init)
    let epoch = try r.parsed("daemon_epoch", DaemonEpoch.init)
    let result = r.raw("result")
    let error = r.raw("error")
    try r.finish()
    let outcome: Result<JSONValue, HostControlError>
    switch (result, error) {
    case (let result?, nil): outcome = .success(result)
    case (nil, let error?): outcome = .failure(try HostControlError(wire: error))
    default: throw .invalidRequest("response must carry exactly one of result or error")
    }
    return HostResponse(
      requestID: requestID, hostID: hostID, ownerID: ownerID, epoch: epoch, outcome: outcome)
  }

  /// Correlation and identity checks a client applies before trusting data.
  /// `expected` is nil only for the first hello of an enrollment.
  package func validated(
    for request: HostRequest, expected: (HostID, OwnerID)?
  ) throws(HostControlError) -> HostResponse {
    guard requestID == request.requestID else {
      throw .invalidRequest("response request_id does not match the request")
    }
    if let (host, owner) = expected {
      guard hostID == host else {
        throw HostControlError(.hostIdentityChanged, "host identity changed since enrollment")
      }
      guard ownerID == owner else {
        throw HostControlError(.ownerMismatch, "host owner changed since enrollment")
      }
    }
    return self
  }
}
