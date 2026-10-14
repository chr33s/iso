import Foundation
import Testing

@testable import IsoPolicy

/// Fixture bytes; text fixtures end in one newline the hygiene check requires.
func fixture(_ name: String) throws -> [UInt8] {
  let url = try #require(
    Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
  var bytes = Array(try Data(contentsOf: url))
  if bytes.last == 0x0A { bytes.removeLast() }
  return bytes
}

func tree(_ json: String) throws -> PolicyJSON {
  try PolicyCanonical.tree(JSONSerialization.jsonObject(with: Data(json.utf8)), [])
}

func compile(_ json: String) throws -> CompiledPolicy {
  try PolicyCompiler.compile(PolicyDocument.parse(tree(json)))
}

func compileError(_ json: String) -> PolicyError? {
  do {
    _ = try compile(json)
    return nil
  } catch let error as PolicyError {
    return error
  } catch {
    return nil
  }
}

func policyJSON(
  mode: String = "enforce",
  actions: [String] = ["credential.use", "proxy.request", "workspace.pull.apply"],
  rules: String = "", guards: String = ""
) -> String {
  let list = actions.map { "\"\($0)\"" }.joined(separator: ",")
  return
    "{\"version\":1,\"mode\":\"\(mode)\",\"actions\":[\(list)],\"rules\":[\(rules)],\"guards\":[\(guards)]}"
}

func rule(
  _ id: String, _ effect: String = "permit", _ action: String, _ resources: [String],
  instances: [String]? = nil
) -> String {
  var text =
    "{\"id\":\"\(id)\",\"effect\":\"\(effect)\",\"action\":\"\(action)\",\"resources\":[\(resources.map { "\"\($0)\"" }.joined(separator: ","))]"
  if let instances {
    text += ",\"instances\":[\(instances.map { "\"\($0)\"" }.joined(separator: ","))]"
  }
  return text + "}"
}

func rateGuard(
  _ id: String, _ resources: [String] = ["provider:anthropic"], max: Int, within: Int,
  instances: [String]? = nil
) -> String {
  var text =
    "{\"id\":\"\(id)\",\"action\":\"proxy.request\",\"resources\":[\(resources.map { "\"\($0)\"" }.joined(separator: ","))],\"require\":{\"rate_limit\":{\"max_requests\":\(max),\"within_seconds\":\(within)}}"
  if let instances {
    text += ",\"instances\":[\(instances.map { "\"\($0)\"" }.joined(separator: ","))]"
  }
  return text + "}"
}

func approvalGuard(_ id: String, seconds: Int) -> String {
  "{\"id\":\"\(id)\",\"action\":\"workspace.pull.apply\",\"resources\":[\"workspace:attached\"],\"require\":{\"approval_within\":{\"seconds\":\(seconds)}}}"
}

let anthropicPermits =
  rule("use", "permit", "credential.use", ["provider:anthropic"]) + ","
  + rule("request", "permit", "proxy.request", ["provider:anthropic"])

/// An integer fake clock for exact boundary tests; tests only.
let second: UInt64 = 1_000_000_000
