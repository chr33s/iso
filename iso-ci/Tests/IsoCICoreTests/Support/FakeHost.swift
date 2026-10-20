import Foundation
import Synchronization

@testable import IsoCICore

/// An in-process `iso.host/v1` host for execution tests: durable operations
/// are idempotent by operation id, and replies can be dropped after the
/// effect is applied (a lost reply) or refused before it (unreachable).
final class FakeHost: HostTransport, @unchecked Sendable {
  struct Run {
    var id: String
    var generation: UInt64
    var phase: String
    var instance: String
    var liveUntil: UInt64?
    var retentionDeadline: UInt64?
  }

  struct State {
    var runs: [String: Run] = [:]
    var operations: [String: (method: String, digest: String, state: String, outcome: String?)] =
      [:]
    var creates = 0
    var dropReplies: Set<String> = []
    var unreachable = false
    var proofPolicy: String
    var capabilities: JSONValue
    var calls: [String] = []
    var bootPhase = "running"
    /// After a discard succeeds, later calls are unreachable (lost host).
    var unreachableAfterDiscard = false
  }

  let hostID = HostID.generate()
  let ownerID = try! OwnerID(String(repeating: "ab", count: 16))
  let epoch = DaemonEpoch.generate()
  let state: Mutex<State>

  static let grantFreePolicy = String(repeating: "1", count: 64)

  init(capabilities: JSONValue = FakeHost.qualifiedCapabilities()) {
    state = Mutex(State(proofPolicy: Self.grantFreePolicy, capabilities: capabilities))
  }

  static func qualifiedCapabilities(
    advertise: Bool = true, status: String = "qualified", providers: [String] = [],
    allowed: [String] = ["github.com", "api.github.com"], expiresAt: UInt64? = nil,
    image: String = "ci-runner@sha256:" + String(repeating: "0", count: 64)
  ) -> JSONValue {
    var qualification: [String: JSONValue] = [
      "schema": "iso.qualification/v1", "status": .string(status),
      "manifest_digest": .string(String(repeating: "c", count: 64)),
      "tuple": [
        "host_os": "27.0", "transport": "brokered",
        "image": .string(image),
      ], "tests": ["N-T01": "passed"],
    ]
    if let expiresAt { qualification["expires_at"] = .integer(Int64(expiresAt)) }
    let policy: (Bool) -> JSONValue = { filtered in
      [
        "digest": .string(grantFreePolicy),
        "public_egress": filtered
          ? [
            "profile": "filtered", "allowed_hosts": .array(allowed.map { .string($0) }),
            "policy_hash": "sha256:x",
          ]
          : .null,
        "provider_grants": .array(providers.map { .string($0) }), "local_services": [],
        "channel_policy": .string(String(repeating: "2", count: 64)),
      ]
    }
    return [
      "capabilities": .array(
        (advertise ? [HostCapabilityName.netHandoff1, .runRetention1] : [.runRetention1]).map {
          .string($0.rawValue)
        }),
      "network_handoff": [
        "id": "NET-HANDOFF-1", "version": 1, "transport": "brokered", "fallback": "forbidden",
        "run_policies": ["none": policy(false), "filtered": policy(true)],
      ],
      "qualification": .object(qualification),
      "run_retention": [
        "modes": ["live", "stopped"], "max_live_seconds": 14_400, "max_stopped_seconds": 604_800,
      ],
      "limits": ["retention_slots": 4, "max_output_bytes": 268_435_456, "max_ttl_seconds": 86_400],
    ]
  }

  var instanceWire: (String) -> JSONValue {
    { [hostID, ownerID] id in
      [
        "host_id": .string(hostID.rawValue), "owner_id": .string(ownerID.rawValue),
        "instance_id": .string(id), "runtime_id": "iso-abababab-0011223344556677",
        "guest_os": "linux",
      ]
    }
  }

  func exchange(_ frame: [UInt8]) throws(CIError) -> [UInt8] {
    let request = try StrictJSON.parse(Array(frame.dropLast()), limits: .control)
    guard let method = request["method"]?.stringValue,
      let requestID = request["request_id"]?.stringValue,
      let params = request["params"]
    else { throw CIError.invalid("bad frame") }
    let operation = request["operation_id"]?.stringValue
    let (result, drop): (Result<JSONValue, WireFailure>, Bool) = try state.withLock {
      (state) throws(CIError) in
      state.calls.append(method)
      if state.unreachable { throw CIError(.hostUnreachable, "unreachable") }
      if state.unreachableAfterDiscard,
        state.operations.values.contains(where: { $0.method == "run.results.discard" }),
        method != "run.results.discard", method != "operation.get"
      {
        throw CIError(.hostUnreachable, "unreachable")
      }
      return (handle(method, params, operation, &state), state.dropReplies.contains(method))
    }
    if drop { throw CIError(.hostUnreachable, "reply lost") }
    var response: [String: JSONValue] = [
      "protocol": "iso.host/v1", "request_id": .string(requestID),
      "host_id": .string(hostID.rawValue),
      "owner_id": .string(ownerID.rawValue), "daemon_epoch": .string(epoch.rawValue),
    ]
    switch result {
    case .success(let value): response["result"] = value
    case .failure(let error): response["error"] = error.value
    }
    return JSONValue.object(response).canonical
  }

  private func error(_ code: String, _ message: String) -> Result<JSONValue, WireFailure> {
    .failure(
      WireFailure(value: [
        "code": .string(code), "message": .string(message), "retry": "unsupported",
      ]))
  }

  private func receipt(
    _ id: String, _ op: (method: String, digest: String, state: String, outcome: String?),
    _ disposition: String
  ) -> JSONValue {
    var value: [String: JSONValue] = [
      "operation_id": .string(id), "method": .string(op.method), "state": .string(op.state),
      "disposition": .string(disposition), "accepted_at": 1, "cancel_requested": false,
    ]
    if let outcome = op.outcome { value["outcome"] = .string(outcome) }
    return .object(value)
  }

  private func runWire(_ run: Run) -> JSONValue {
    var value: [String: JSONValue] = [
      "run_id": .string(run.id), "generation": .integer(Int64(run.generation)),
      "phase": .string(run.phase),
      "instance_id": .string(run.instance), "runtime_id": "iso-abababab-0011223344556677",
      "recovery_used": false,
    ]
    if let live = run.liveUntil { value["live_retention_until"] = .integer(Int64(live)) }
    if let deadline = run.retentionDeadline {
      value["retention_deadline"] = .integer(Int64(deadline))
    }
    return .object(value)
  }

  private func durable(
    _ method: String, _ params: JSONValue, _ operation: String?, _ state: inout State,
    apply: (inout State) -> String?
  ) -> Result<JSONValue, WireFailure> {
    guard let operation else { return error("INVALID_REQUEST", "operation_id is required") }
    let digest = Digest(hashing: params.canonical).rawValue
    if let existing = state.operations[operation] {
      guard existing.digest == digest, existing.method == method else {
        return error("OPERATION_ID_CONFLICT", "different request")
      }
      return .success(receipt(operation, existing, "existing"))
    }
    let outcome = apply(&state)
    let record = (method, digest, outcome == nil ? "succeeded" : "failed", outcome)
    state.operations[operation] = record
    return .success(receipt(operation, record, "accepted"))
  }

  private func handle(
    _ method: String, _ params: JSONValue, _ operation: String?, _ state: inout State
  )
    -> Result<JSONValue, WireFailure>
  {
    switch method {
    case "hello":
      return .success([
        "protocol": "iso.host/v1", "host_id": .string(hostID.rawValue),
        "owner_id": .string(ownerID.rawValue),
        "daemon_epoch": .string(epoch.rawValue),
        "runtime": ["status": "qualified", "detail": "test"],
        "methods": .array(HostMethod.allCases.map { .string($0.rawValue) }), "guest_os": ["linux"],
      ])
    case "host.capabilities":
      return .success(state.capabilities)
    case "run.create":
      return durable(method, params, operation, &state) { state in
        guard let id = params["run_id"]?.stringValue else { return "bad" }
        state.creates += 1
        state.runs[id] = Run(
          id: id, generation: 3, phase: state.bootPhase, instance: InstanceID.generate().rawValue,
          liveUntil: nil, retentionDeadline: nil)
        return nil
      }
    case "operation.get":
      guard let id = params["operation_id"]?.stringValue, let op = state.operations[id] else {
        return error("OPERATION_NOT_FOUND", "unknown operation")
      }
      return .success(receipt(id, op, "existing"))
    case "run.inspect":
      guard let id = params["run_id"]?.stringValue, let run = state.runs[id] else {
        return error("RESULTS_UNAVAILABLE", "unknown run")
      }
      return .success(runWire(run))
    case "vm.inspect":
      guard let instance = params["instance"]?["instance_id"]?.stringValue,
        let run = state.runs.values.first(where: { $0.instance == instance })
      else { return error("INSTANCE_NOT_FOUND", "unknown") }
      return .success([
        "instance": instanceWire(instance), "name": "ci", "generation": 2,
        "state": run.phase == "running" ? "running" : "stopped", "boot_id": "boot-1",
        "policy_hash": .string(String(repeating: "d", count: 64)), "observed_at": 5,
        "image": "ci-runner", "egress": "filtered",
        "network": [
          "transport": "brokered", "boot_id": "boot-1", "external_nic_count": 0,
          "network_policy_digest": .string(state.proofPolicy),
          "channel_policy_digest": .string(String(repeating: "2", count: 64)),
        ],
      ])
    case "run.complete":
      return durable(method, params, operation, &state) { state in
        guard let id = params["run_id"]?.stringValue, var run = state.runs[id],
          run.phase == "running"
        else {
          return "run is not running"
        }
        run.phase = "stopped_disk_pending_export"
        run.generation += 1
        run.retentionDeadline = 9_999
        state.runs[id] = run
        return nil
      }
    case "run.retain":
      return durable(method, params, operation, &state) { state in
        guard let id = params["run_id"]?.stringValue, var run = state.runs[id] else {
          return "unknown run"
        }
        if params["mode"]?.stringValue == "live" {
          guard run.phase == "running" else { return "run is not running" }
          run.liveUntil = 5_000
        } else {
          run.retentionDeadline = 50_000
        }
        run.generation += 1
        state.runs[id] = run
        return nil
      }
    case "run.results.discard":
      return durable(method, params, operation, &state) { state in
        guard let id = params["run_id"]?.stringValue, var run = state.runs[id] else {
          return "unknown run"
        }
        if run.phase == "running" && run.liveUntil == nil { return "run is running" }
        run.phase = "destroyed"
        run.generation += 1
        state.runs[id] = run
        return nil
      }
    default:
      return error("UNSUPPORTED_CAPABILITY", "not faked: \(method)")
    }
  }
}

struct WireFailure: Error {
  let value: JSONValue
}

struct FixedClock: CIClock {
  let value: EpochSeconds
  func now() -> EpochSeconds { value }
}

/// A clock tests advance by hand.
final class TestClock: CIClock, Sendable {
  private let time: Mutex<EpochSeconds>
  init(_ start: EpochSeconds = 1_800_000_000) { time = Mutex(start) }
  func now() -> EpochSeconds { time.withLock { $0 } }
  func advance(_ seconds: EpochSeconds) { time.withLock { $0 += seconds } }
}

/// A fresh, unique path under the temporary directory for one test.
func scratchDirectory(_ purpose: String) -> String {
  NSTemporaryDirectory() + "iso-ci-\(purpose)-" + randomHex(bytes: 6)
}

enum TestConfig {
  static let yaml = CIConfiguration.template(repository: "octo/demo", host: "local")

  static func configuration() throws -> CIConfiguration { try CIConfiguration.parse(yaml) }
}
