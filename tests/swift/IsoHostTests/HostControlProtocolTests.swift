import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

@Suite struct HostControlProtocolTests {
  let host = HostID.generate()
  let owner = try! OwnerID(String(repeating: "cd", count: 16))

  func frame(_ text: String) -> [UInt8] { Array(text.utf8) }

  func uncorrelated(_ bytes: [UInt8]) -> Bool {
    if case .uncorrelated? = decodeFailure(bytes) { return true }
    return false
  }

  func decodeFailure(_ bytes: [UInt8]) -> HostRequest.DecodeFailure? {
    do {
      _ = try HostRequest.decode(frame: bytes)
      return nil
    } catch { return error }
  }

  @Test func identitiesValidateCanonicalForms() throws {
    let id = HostOperationID.generate()
    #expect(try HostOperationID(id.rawValue) == id)
    #expect(throws: ValidationError.self) { try HostID("11111111-1111-4111-8111-11111111111") }
    #expect(throws: ValidationError.self) { try HostID("11111111-1111-4111-8111-11111111111G") }
    #expect(throws: ValidationError.self) {
      try HostID("aaaaaaaa-1111-4111-8111-111111111111".uppercased())
    }
    #expect(throws: ValidationError.self) { try HostAlias("-oProxyCommand=x") }
    #expect(throws: ValidationError.self) { try HostAlias("a b") }
    #expect(throws: ValidationError.self) { try HostAlias("") }
    #expect(try HostAlias("build-mac.lan").rawValue == "build-mac.lan")
    #expect(throws: ValidationError.self) { try AccessBearer(String(repeating: "a", count: 62)) }
    #expect(AccessBearer.generate().rawValue.utf8.count == 64)
    // Host and runtime operation identities are distinct retry domains.
    #expect(id.runtimeOperation.rawValue == "h-" + id.rawValue)
  }

  @Test func requestRoundTripsAndDigestIgnoresRequestID() throws {
    let spec = try VMSpec.make(
      name: InstanceName("p"), image: .default, imageDigest: nil, cpus: 2, memoryMiB: 2048,
      diskGiB: 8, guestOS: .linux, egress: .none)
    let operation = HostOperationID.generate()
    let a = HostRequest(hostID: host, ownerID: owner, operationID: operation, body: .vmCreate(spec))
    let b = HostRequest(hostID: host, ownerID: owner, operationID: operation, body: .vmCreate(spec))
    #expect(a.requestID != b.requestID)
    #expect(a.digest == b.digest)
    let decoded = try HostRequest.decode(frame: Array(a.frame.dropLast()))
    #expect(decoded == a)
    #expect(decoded.digest == a.digest)
    let changed = try VMSpec.make(
      name: InstanceName("p"), image: .default, imageDigest: nil, cpus: 3, memoryMiB: 2048,
      diskGiB: 8, guestOS: .linux, egress: .none)
    let c = HostRequest(
      hostID: host, ownerID: owner, operationID: operation, body: .vmCreate(changed))
    #expect(c.digest != a.digest)
  }

  @Test func canonicalEncodingIsKeyOrderIndependent() throws {
    let one = try HostWire.parse(
      frame(#"{"b":1,"a":{"y":"\u0001","x":[true,null]}}"#), limits: HostWire.requestLimits)
    let two = try HostWire.parse(
      frame(#"{"a":{"x":[true,null],"y":"\u0001"},"b":1}"#), limits: HostWire.requestLimits)
    #expect(HostWire.canonical(one) == HostWire.canonical(two))
    #expect(
      String(decoding: HostWire.canonical(one), as: UTF8.self)
        == #"{"a":{"x":[true,null],"y":"\u0001"},"b":1}"#)
  }

  @Test func malformedFramesCloseWithoutCorrelation() {
    #expect(uncorrelated(frame("not json")))
    #expect(uncorrelated([0xff, 0xfe, 0x7b, 0x7d]))
    #expect(uncorrelated(frame(#"{"request_id":"x","request_id":"y"}"#)))
    #expect(uncorrelated(frame(#"{"protocol":"iso.host/v1"}"#)))
    #expect(uncorrelated(frame(#"{"request_id":"\#(RequestID.generate())","n":1e999}"#)))
    let deep = String(repeating: "[", count: 40) + String(repeating: "]", count: 40)
    #expect(uncorrelated(frame(#"{"request_id":"\#(RequestID.generate())","d":\#(deep)}"#)))
    let big = String(repeating: "a", count: HostWire.maxRequestFrame)
    #expect(uncorrelated(frame(#"{"request_id":"\#(RequestID.generate())","x":"\#(big)"}"#)))
  }

  @Test func structurallyInvalidRequestsAreTypedErrors() {
    let id = RequestID.generate()
    func code(_ text: String) -> HostControlError.Code? {
      if case .correlated(let rid, let error)? = decodeFailure(frame(text)), rid == id {
        return error.code
      }
      return nil
    }
    let envelope = #""request_id":"\#(id)","host_id":"\#(host)","owner_id":"\#(owner)""#
    #expect(
      code(#"{\#(envelope),"protocol":"iso.host/v2","method":"hello","params":{}}"#)
        == .hostProtocolIncompatible)
    #expect(
      code(#"{\#(envelope),"protocol":"iso.host/v1","method":"vm.nuke","params":{}}"#)
        == .invalidRequest)
    // Unknown closed field.
    #expect(
      code(
        #"{\#(envelope),"protocol":"iso.host/v1","method":"vm.list","params":{"limit":5,"extra":1}}"#
      ) == .invalidRequest)
    #expect(
      code(
        #"{\#(envelope),"protocol":"iso.host/v1","method":"vm.list","params":{"limit":5},"x":1}"#)
        == .invalidRequest)
    // Bounds and types.
    #expect(
      code(#"{\#(envelope),"protocol":"iso.host/v1","method":"vm.list","params":{"limit":0}}"#)
        == .invalidRequest)
    #expect(
      code(#"{\#(envelope),"protocol":"iso.host/v1","method":"vm.list","params":{"limit":"5"}}"#)
        == .invalidRequest)
    #expect(
      code(#"{\#(envelope),"protocol":"iso.host/v1","method":"vm.list","params":{"limit":2.0}}"#)
        == .invalidRequest)
    // Mutations require an operation id; reads refuse one.
    let instance =
      #"{"host_id":"\#(host)","owner_id":"\#(owner)","instance_id":"\#(InstanceID.generate())","runtime_id":"iso-cdcdcdcd-0011223344556677","guest_os":"linux"}"#
    #expect(
      code(
        #"{\#(envelope),"protocol":"iso.host/v1","method":"vm.stop","params":{"instance":\#(instance),"expected_generation":1}}"#
      ) == .invalidRequest)
    #expect(
      code(
        #"{\#(envelope),"protocol":"iso.host/v1","method":"vm.list","operation_id":"\#(HostOperationID.generate())","params":{"limit":5}}"#
      ) == .invalidRequest)
    // host/owner are required beyond hello.
    #expect(
      code(
        #"{"request_id":"\#(id)","protocol":"iso.host/v1","method":"vm.list","params":{"limit":5}}"#
      ) == .invalidRequest)
  }

  @Test func responsesAreValidatedBeforeUse() throws {
    let request = HostRequest(hostID: host, ownerID: owner, body: .vmList(cursor: nil, limit: 1))
    let epoch = DaemonEpoch.generate()
    let good = HostResponse(
      requestID: request.requestID, hostID: host, ownerID: owner, epoch: epoch,
      outcome: .success(.object([:])))
    let decoded = try HostResponse.decode(frame: Array(good.frame.dropLast()))
    #expect(decoded == good)
    #expect(throws: Never.self) { try decoded.validated(for: request, expected: (host, owner)) }
    let other = HostRequest(hostID: host, ownerID: owner, body: .vmList(cursor: nil, limit: 1))
    #expect(throws: HostControlError.self) {
      try decoded.validated(for: other, expected: (host, owner))
    }
    do {
      _ = try decoded.validated(for: request, expected: (.generate(), owner))
      Issue.record("changed host identity was accepted")
    } catch { #expect(error.code == .hostIdentityChanged) }
    let otherOwner = try OwnerID(String(repeating: "ef", count: 16))
    do {
      _ = try decoded.validated(for: request, expected: (host, otherOwner))
      Issue.record("changed owner was accepted")
    } catch { #expect(error.code == .ownerMismatch) }
    // A response carrying both result and error is refused.
    let both =
      #"{"protocol":"iso.host/v1","request_id":"\#(request.requestID)","host_id":"\#(host)","owner_id":"\#(owner)","daemon_epoch":"\#(epoch)","result":{},"error":{"code":"INVALID_REQUEST","message":"","retry":"unsupported","details":{}}}"#
    #expect(throws: HostControlError.self) { try HostResponse.decode(frame: frame(both)) }
  }

  @Test func errorsAreSanitizedAndBounded() throws {
    let error = HostControlError(
      .instanceBusy, "bad\u{1b}[31m" + String(repeating: "x", count: 2_000),
      details: Dictionary(uniqueKeysWithValues: (0..<40).map { ("k\($0)", "v") }))
    #expect(!error.message.unicodeScalars.contains { $0.value < 0x20 })
    #expect(error.message.utf8.count <= HostControlError.maxMessageBytes)
    #expect(error.details.count == HostControlError.maxDetails)
    #expect(error.retry == .refreshObservationThenNewOperation)
    #expect(try HostControlError(wire: error.wire) == error)
    for code in HostControlError.Code.allCases {
      #expect(HostControlError.Retry.allCases.contains(code.defaultRetry))
    }
  }

  @Test func helloAdvertisesOnlyDispatchedMethods() throws {
    let fixture = try SupervisorFixture()
    defer { fixture.cleanup() }
    let request = HostRequest(
      hostID: nil, ownerID: nil, body: .hello(protocols: [HostProtocol.v1], clientBuild: "test"))
    let response = fixture.supervisor.handle(request, transport: .ssh)
    let hello = try HelloResult(wire: response.outcome.get())
    #expect(hello.hostID == fixture.hostID)
    #expect(hello.ownerID == fixture.owner)
    #expect(hello.epoch == fixture.supervisor.epoch)
    #expect(!hello.methods.contains(.vmResize))
    #expect(!hello.methods.contains(.macosComputerUseInput))
    #expect(hello.methods.contains(.vmCreate))
    #expect(hello.guestOperations == [.linux])
    let incompatible = HostRequest(
      hostID: nil, ownerID: nil, body: .hello(protocols: ["iso.host/v9"], clientBuild: "test"))
    #expect(
      failure(fixture.supervisor.handle(incompatible, transport: .ssh).outcome)
        == .hostProtocolIncompatible)
  }

  @Test func wrongHostOrOwnerIsRefusedBeforeDispatch() throws {
    let fixture = try SupervisorFixture()
    defer { fixture.cleanup() }
    let wrongHost = HostRequest(
      hostID: .generate(), ownerID: fixture.owner, body: .vmList(cursor: nil, limit: 5))
    #expect(
      failure(fixture.supervisor.handle(wrongHost, transport: .ssh).outcome) == .hostIdentityChanged
    )
    let wrongOwner = HostRequest(
      hostID: fixture.hostID, ownerID: try OwnerID(String(repeating: "01", count: 16)),
      body: .vmList(cursor: nil, limit: 5))
    #expect(
      failure(fixture.supervisor.handle(wrongOwner, transport: .ssh).outcome) == .ownerMismatch)
  }
}
