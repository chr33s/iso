import ArgumentParser
import Foundation
import IsoCICore

@main
struct IsoCICommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "iso-ci",
    abstract: "Isolated GitHub Actions execution on iso brokered VMs",
    discussion: """
      GitHub-connected pools supply fresh, single-use official runners; local preflight runs a \
      declared workflow subset against an immutable working-tree snapshot. Every job runs in one \
      clean NIC-less iso VM. See docs/ci.md.
      """,
    version: IsoCIVersion.current,
    subcommands: [
      Setup.self, Serve.self, Status.self, PoolCommand.self, Run.self, Logs.self, Inspect.self,
      Debug.self, Patch.self, Retry.self, Abort.self, Results.self, Actions.self,
      RelayHelper.self,
    ])
}

extension IsoCICommand {
  /// The confined data-plane child is dispatched before argument parsing:
  /// it runs under its Seatbelt profile with an empty environment and must
  /// not touch the controller's state, configuration or credentials.
  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "_dataplane" {
      let rest = Array(arguments.dropFirst())
      Darwin.exit(blocking { await DataPlaneChild.main(arguments: rest) })
    }
    main(nil)
  }
}

struct GlobalOptions: ParsableArguments {
  @Option(help: "Controller data root (default: $ISO_CI_HOME or ~/.iso-ci)") var root: String?
  @Option(help: "The installed iso executable (recorded on first use)") var iso: String?
  @Option(
    name: .customLong("iso-config"),
    help: "A dedicated iso config file for CI hosts (recorded on first use; default ~/.iso)")
  var isoConfig: String?
  @Flag(help: "Machine-readable JSON output with typed status codes") var json = false

  var dataRoot: DataRoot {
    if let root, root.hasPrefix("/") { return DataRoot(path: root) }
    return DataRoot.default(environment: ProcessInfo.processInfo.environment)
  }

  func dispatcher() -> ControlDispatcher {
    let root = dataRoot
    let iso = self.iso
    let isoConfig = self.isoConfig
    return ControlDispatcher(root: root) { () throws(CIError) -> Runtime in
      let runtime = try Runtime.open(
        root: root, iso: iso, isoConfig: isoConfig,
        environment: ProcessInfo.processInfo.environment)
      try Services.install(runtime)
      return runtime
    }
  }

  /// Runs `body`, printing a typed error and exiting non-zero on failure.
  func run(_ body: () throws(CIError) -> Void) throws {
    do throws(CIError) { try body() } catch {
      Output.failure(error, json: json)
      throw ExitCode(Output.exitCode(error))
    }
  }

  func call(_ method: String, _ params: JSONValue = [:]) throws(CIError) -> JSONValue {
    try dispatcher().call(method, params)
  }
}

enum Output {
  static func print(_ value: JSONValue) {
    FileHandle.standardOutput.write(Data(value.canonical + [0x0A]))
  }

  static func line(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
  }

  /// Diagnostics go to stderr.
  static func note(_ text: String) {
    FileHandle.standardError.write(Data(("iso-ci: " + text + "\n").utf8))
  }

  static func failure(_ error: CIError, json: Bool) {
    if json {
      FileHandle.standardOutput.write(
        Data(JSONValue.object(["ok": false, "error": error.json]).canonical + [0x0A]))
    } else {
      note("\(error.code.rawValue): \(error.message)")
      // Details (for example every compatibility problem) in key order.
      for key in error.details.keys.sorted() { note("  \(error.details[key] ?? "")") }
    }
  }

  static func exitCode(_ error: CIError) -> Int32 {
    switch error.code {
    case .invalidRequest, .invalidConfiguration, .compatibilityRejected: 2
    case .controllerUnavailable, .hostUnreachable, .githubUnavailable: 3
    case .operationUncertain, .registrationUncertain: 4
    case .capabilityMissing, .qualificationMissing, .admissionRefused, .confinementUnavailable: 5
    default: 1
    }
  }

  static func emit(_ value: JSONValue, json: Bool, human: (JSONValue) -> Void) {
    if json { print(["ok": true, "result": value]) } else { human(value) }
  }
}

func string(_ value: JSONValue?) -> String {
  switch value {
  case .string(let text)?: text
  case .integer(let number)?: String(number)
  case .bool(let flag)?: String(flag)
  case .null?, nil: "-"
  case let other?: other.canonicalString
  }
}

// MARK: - serve

struct Serve: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Run the controller in the foreground, or install/remove the user service",
    discussion: """
      The controller holds workload leases; a disconnected CLI never revokes them. A user service \
      runs only while you are logged in: sleep, restart and logout stop it, and the GitHub App key \
      in the login keychain is readable only while the keychain is unlocked.
      """)

  @OptionGroup var global: GlobalOptions
  @Flag(help: "Explicitly install and start the per-user launchd service") var install = false
  @Flag(help: "Stop and remove the per-user launchd service") var uninstall = false
  @Option(help: "Reconciliation interval in seconds") var interval: Double = 15

  func validate() throws {
    if install && uninstall { throw ValidationError("--install and --uninstall are exclusive") }
    guard (2...600).contains(interval) else { throw ValidationError("--interval must be 2-600") }
  }

  func run() throws {
    try global.run { () throws(CIError) in
      if install || uninstall {
        let result = try UserService.apply(
          install: install, root: global.dataRoot, executable: try Runtime.currentExecutable(),
          iso: global.iso)
        Output.emit(result, json: global.json) { _ in
          Output.line(
            install
              ? "Installed and started the iso-ci user service" : "Removed the iso-ci user service")
        }
        return
      }
      let runtime = try Runtime.open(
        root: global.dataRoot, iso: global.iso, isoConfig: global.isoConfig,
        environment: ProcessInfo.processInfo.environment)
      try Services.install(runtime)
      Output.note("controller serving \(global.dataRoot.path)")
      try runtime.controller.run()
    }
  }
}

// MARK: - status

struct Status: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Pool capacity, allocations, qualification, availability and unresolved cleanup")

  @OptionGroup var global: GlobalOptions

  func run() throws {
    try global.run { () throws(CIError) in
      let value = try global.call("status")
      Output.emit(value, json: global.json) { value in
        Output.line("controller \(string(value["controller_id"]))")
        if value["configuration"]?["valid"] == .bool(false) {
          Output.line(
            "configuration: INVALID — \(string(value["configuration"]?["error"])) (all pools inactive)"
          )
        }
        Output.line("hosts:")
        for host in value["hosts"]?.arrayValue ?? [] {
          Output.line(
            "  \(string(host["alias"])) \(string(host["state"])) net-handoff-1=\(string(host["net_handoff_1"])) qualification=\(string(host["qualification"])) image=\(string(host["qualified_image"])) live=\(string(host["live_vms"])) uncertain=\(string(host["uncertain"]))"
          )
        }
        for (name, section) in (value["services"]?.objectValue ?? [:]).sorted(by: {
          $0.key < $1.key
        }) {
          Output.line("\(name):")
          for (key, entry) in (section.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            Output.line("  \(key): \(entry.canonicalString)")
          }
        }
        Output.line("allocations:")
        for row in value["allocations"]?.arrayValue ?? [] {
          Output.line(
            "  \(string(row["id"])) \(string(row["kind"])) \(string(row["host"])) \(string(row["phase"])) exec=\(string(row["execution"])) export=\(string(row["export"])) cleanup=\(string(row["vm_cleanup"])) registration=\(string(row["registration"]))"
          )
        }
        let debt = value["unresolved_cleanup"]?.arrayValue ?? []
        Output.line("unresolved cleanup: \(debt.count)")
        for row in debt {
          Output.line(
            "  \(string(row["id"])) \(string(row["vm_cleanup"])) \(string(row["registration"])) \(string(row["uncertainty"]))"
          )
        }
      }
    }
  }
}

// MARK: - pool

struct PoolCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pool", abstract: "Pause, drain, resume or offboard a connected pool",
    subcommands: [
      PoolPause.self, PoolDrain.self, PoolResume.self, PoolRemove.self, PoolResolve.self,
    ])
}

struct PoolPause: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pause", abstract: "Stop replenishment without killing assigned work")
  @OptionGroup var global: GlobalOptions
  @Argument var pool: String

  func run() throws {
    try global.run { () throws(CIError) in
      let value = try global.call("pool.pause", ["pool": .string(pool)])
      Output.emit(value, json: global.json) { _ in Output.line("Paused \(pool)") }
    }
  }
}

struct PoolDrain: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "drain",
    abstract: "Stop replenishment and retire idle runners; assigned work finishes within its bounds"
  )
  @OptionGroup var global: GlobalOptions
  @Argument var pool: String
  @Flag(help: "Also stop assigned work now (explicit abort)") var abort = false

  func run() throws {
    try global.run { () throws(CIError) in
      let value = try global.call("pool.drain", ["pool": .string(pool), "abort": .bool(abort)])
      Output.emit(value, json: global.json) { _ in
        Output.line("Draining \(pool)\(abort ? " (aborting assigned work)" : "")")
      }
    }
  }
}

struct PoolResume: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "resume", abstract: "Resume replenishment of a paused or drained pool")
  @OptionGroup var global: GlobalOptions
  @Argument var pool: String

  func run() throws {
    try global.run { () throws(CIError) in
      let value = try global.call("pool.resume", ["pool": .string(pool)])
      Output.emit(value, json: global.json) { _ in Output.line("Resumed \(pool)") }
    }
  }
}

struct PoolRemove: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "remove",
    abstract: "Offboard only this controller's owned CI resources and report pending cleanup")
  @OptionGroup var global: GlobalOptions
  @Argument var pool: String
  @Flag(help: "Also remove the pool's CI-only GitHub App credentials (explicit)")
  var removeCredentials = false

  func run() throws {
    try global.run { () throws(CIError) in
      let value = try global.call(
        "pool.remove", ["pool": .string(pool), "remove_credentials": .bool(removeCredentials)])
      Output.emit(value, json: global.json) { value in
        Output.line("Offboarding \(pool): \(value.canonicalString)")
      }
    }
  }
}

struct PoolResolve: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "resolve",
    abstract: "Resolve an uncertain runner registration after checking GitHub yourself",
    discussion:
      "Give the exact runner id GitHub shows for this allocation's runner name (it is deleted), or --none if no such runner exists. iso-ci never guesses by name prefix."
  )
  @OptionGroup var global: GlobalOptions
  @Argument var allocation: String
  @Option(help: "The GitHub runner id registered under this allocation's runner name") var runnerID:
    Int64?
  @Flag(help: "Assert that no runner with this allocation's name exists") var none = false

  func validate() throws {
    guard (runnerID == nil) != !none else {
      throw ValidationError("give exactly one of --runner-id or --none")
    }
  }

  func run() throws {
    try global.run { () throws(CIError) in
      var params: [String: JSONValue] = ["allocation": .string(allocation)]
      if let runnerID { params["runner_id"] = .integer(runnerID) }
      let value = try global.call("registration.resolve", .object(params))
      Output.emit(value, json: global.json) { _ in
        Output.line("Resolved the registration of \(allocation)")
      }
    }
  }
}

// MARK: - preflight

struct Run: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Submit a local preflight run of a workflow against a working-tree snapshot")

  @OptionGroup var global: GlobalOptions
  @Argument(help: "Workflow file (for example .github/workflows/ci.yml)") var workflow: String
  @Option(help: "Host to run on (default: configured eligible hosts)") var host: String?
  @Option(help: "Target platform; only linux/arm64 is supported") var platform: String =
    "linux/arm64"
  @Option(help: "Simulated triggering event") var event: String = "push"
  @Option(help: "Repository working directory (default: the current directory)") var repository:
    String?
  @Option(
    name: .customLong("include"),
    help: "Also include untracked paths matching this pattern (repeatable)")
  var include: [String] = []
  @Option(name: .customLong("exclude"), help: "Exclude paths matching this pattern (repeatable)")
  var exclude: [String] = []
  @Option(
    name: .customLong("secret"),
    help:
      "Map one workflow secret from one named environment variable: NAME=ENV_VAR (repeatable, explicit)"
  )
  var secrets: [String] = []
  @Option(name: .customLong("input"), help: "workflow_dispatch input NAME=VALUE (repeatable)")
  var inputs: [String] = []
  @Flag(help: "Wait for the run and stream its events") var follow = false

  func validate() throws {
    guard platform == "linux/arm64" else {
      throw ValidationError(
        "only linux/arm64 preflight is supported; no implicit architecture translation")
    }
  }

  func run() throws {
    var conclusion: JSONValue?
    try global.run { () throws(CIError) in
      let directory = absolutePath(repository)
      var secretValues: [String: JSONValue] = [:]
      for mapping in secrets {
        let parts = mapping.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
          throw CIError.invalid("--secret must be NAME=ENV_VAR")
        }
        guard let value = ProcessInfo.processInfo.environment[parts[1]] else {
          throw CIError.invalid("environment variable \(parts[1]) is not set")
        }
        secretValues[parts[0]] = .string(value)
      }
      var inputValues: [String: JSONValue] = [:]
      for input in inputs {
        let parts = input.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty else {
          throw CIError.invalid("--input must be NAME=VALUE")
        }
        inputValues[parts[0]] = .string(parts[1])
      }
      var params: [String: JSONValue] = [
        "workflow": .string(workflow), "repository": .string(directory),
        "platform": .string(platform),
        "event": .string(event), "include": .array(include.map { .string($0) }),
        "exclude": .array(exclude.map { .string($0) }), "secrets": .object(secretValues),
        "inputs": .object(inputValues),
      ]
      if let host { params["host"] = .string(host) }
      let value = try global.call("run.submit", .object(params))
      Output.emit(value, json: global.json) { value in
        Output.line(
          "Run \(string(value["run"])) submitted (\(string(value["jobs"])) jobs, snapshot \(string(value["snapshot"])))"
        )
        if value["dirty"] == .bool(true) {
          Output.line(
            "Note: the snapshot includes uncommitted changes; a pass is not evidence for base commit \(string(value["base_commit"]))"
          )
        }
        for (label, key) in [
          ("Included untracked", "included_untracked"), ("Excluded", "excluded"),
        ] {
          let paths = (value[key]?.arrayValue ?? []).compactMap(\.stringValue)
          if !paths.isEmpty { Output.line("\(label): \(paths.joined(separator: ", "))") }
        }
      }
      if follow, let run = value["run"]?.stringValue {
        conclusion = try Logs.follow(global: global, target: run)["run"]?["conclusion"]
      }
    }
    // A followed run that did not succeed exits non-zero.
    if follow, conclusion != .string("success") { throw ExitCode(1) }
  }
}

struct Logs: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Stream bounded local events and diagnostics for a run or allocation")

  @OptionGroup var global: GlobalOptions
  @Argument var target: String
  @Flag(help: "Keep streaming until the run or allocation settles") var follow = false
  @Option(help: "Start after this event cursor") var after: Int64 = 0
  @Option(help: "Print this preflight job's stored runner logs instead of events")
  var job: String?
  @Option(help: "With --job: this attempt number (default: the latest)") var attempt: Int?

  func run() throws {
    try global.run { () throws(CIError) in
      if let job {
        var params: [String: JSONValue] = ["run": .string(target), "job": .string(job)]
        if let attempt { params["attempt"] = .integer(Int64(attempt)) }
        let value = try global.call("job.logs", .object(params))
        if global.json {
          Output.print(value)
          return
        }
        for segment in value["logs"]?.arrayValue ?? [] { Output.line(segment.stringValue ?? "") }
        if value["truncated"] == .bool(true) { Output.line("[logs truncated]") }
      } else if follow {
        try Self.follow(global: global, target: target, after: after)
      } else {
        let value = try global.call(
          "events", ["subject": .string(target), "after": .integer(after)])
        Self.print(value, json: global.json)
      }
    }
  }

  static func print(_ value: JSONValue, json: Bool) {
    if json {
      Output.print(value)
      return
    }
    for event in value["events"]?.arrayValue ?? [] {
      let time = Date(timeIntervalSince1970: Double(event["at"]?.intValue ?? 0))
      Output.line("\(time.ISO8601Format()) \(string(event["kind"])) \(string(event["message"]))")
    }
  }

  /// Streams events until the target settles; returns its final state.
  @discardableResult
  static func follow(global: GlobalOptions, target: String, after: Int64 = 0) throws(CIError)
    -> JSONValue
  {
    var cursor = after
    while true {
      let value = try global.call(
        "events", ["subject": .string(target), "after": .integer(cursor)])
      print(value, json: global.json)
      cursor = value["cursor"]?.intValue ?? cursor
      let state = try global.call("inspect", ["target": .string(target)])
      if state["settled"] == .bool(true)
        || state["allocation"]?["vm_cleanup"] == .string("verified")
      {
        let rest = try global.call(
          "events", ["subject": .string(target), "after": .integer(cursor)])
        print(rest, json: global.json)
        if let link = state["github_url"]?.stringValue { Output.line("GitHub result: \(link)") }
        return state
      }
      Thread.sleep(forTimeInterval: 2)
    }
  }
}

struct Inspect: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Input provenance, host references, job correlation and independent outcomes")
  @OptionGroup var global: GlobalOptions
  @Argument var target: String

  func run() throws {
    try global.run { () throws(CIError) in
      let value = try global.call("inspect", ["target": .string(target)])
      Output.emit(value, json: global.json) { value in Output.line(value.canonicalString) }
    }
  }
}

struct Debug: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Open explicitly authorized access to a live-retained environment",
    discussion:
      "No new privileged credentials are acquired. Secrets already delivered to the guest may remain in its memory, files and disks; network revocation does not erase them."
  )
  @OptionGroup var global: GlobalOptions
  @Argument var allocation: String

  func run() throws {
    var status: Int32 = 0
    try global.run { () throws(CIError) in
      let value = try global.call("debug.open", ["allocation": .string(allocation)])
      guard let ssh = value["ssh"]?.stringValue, let session = value["session"]?.stringValue else {
        throw CIError.invalid("malformed debug reply")
      }
      let arguments = (value["arguments"]?.arrayValue ?? []).compactMap(\.stringValue)
      Output.note("debug session \(session) (closes when you exit)")
      let pid = try Subprocess.spawn(
        ssh, arguments, Subprocess.hostConnectionEnvironment(), stdin: 0, stdout: 1, stderr: 2)
      var raw: Int32 = 0
      while waitpid(pid, &raw, 0) < 0 && errno == EINTR {}
      status = (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 1
      _ = try? global.call("debug.close", ["session": .string(session)])
    }
    if status != 0 { throw ExitCode(status) }
  }
}

struct Patch: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Transfer a new validated snapshot into a retained, non-running preflight environment"
  )
  @OptionGroup var global: GlobalOptions
  @Argument var allocation: String
  @Flag(name: .customLong("from-working-tree"), help: "Capture the snapshot from the working tree")
  var fromWorkingTree =
    false
  @Option(help: "Repository working directory (default: the current directory)") var repository:
    String?

  func validate() throws {
    guard fromWorkingTree else { throw ValidationError("--from-working-tree is required") }
  }

  func run() throws {
    try global.run { () throws(CIError) in
      let value = try global.call(
        "patch",
        [
          "allocation": .string(allocation),
          "repository": .string(absolutePath(repository)),
        ])
      Output.emit(value, json: global.json) { value in
        Output.line(
          "Patched \(allocation): revision \(string(value["revision"])) snapshot \(string(value["snapshot"]))"
        )
      }
    }
  }
}

struct Retry: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Create a fresh whole-job preflight attempt in a clean VM")
  @OptionGroup var global: GlobalOptions
  @Argument var allocation: String
  @Flag(name: .customLong("from-start"), help: "Required: retry restarts the whole job")
  var fromStart = false

  func validate() throws {
    guard fromStart else {
      throw ValidationError("--from-start is required; failed-step continuation is unsupported")
    }
  }

  func run() throws {
    try global.run { () throws(CIError) in
      let value = try global.call("retry", ["allocation": .string(allocation)])
      Output.emit(value, json: global.json) { value in
        Output.line(
          "Retry attempt \(string(value["attempt"])) (allocation \(string(value["allocation"])))")
        if let note = value["provenance_note"]?.stringValue { Output.line("Note: \(note)") }
      }
    }
  }
}

struct Abort: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Request cancellation and an externally enforced stop; keep honest cleanup status")
  @OptionGroup var global: GlobalOptions
  @Argument var target: String

  func run() throws {
    try global.run { () throws(CIError) in
      let value = try global.call("abort", ["target": .string(target)])
      Output.emit(value, json: global.json) { value in
        Output.line("Abort requested: \(value.canonicalString)")
      }
    }
  }
}

struct Results: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Request an allocation's results before it completes, or save the staged archive")
  @OptionGroup var global: GlobalOptions
  @Argument var allocation: String
  @Option(help: "Copy the staged result archive into this directory") var save: String?

  func run() throws {
    try global.run { () throws(CIError) in
      var params: [String: JSONValue] = ["allocation": .string(allocation)]
      if let save { params["save"] = .string(absolutePath(save)) }
      let value = try global.call("results", .object(params))
      Output.emit(value, json: global.json) { value in
        if let path = value["path"]?.stringValue {
          Output.line("Results saved: \(path)")
        } else {
          Output.line("Results: \(value["export"]?.stringValue ?? "unknown")")
        }
      }
    }
  }
}

// MARK: - hidden helpers

struct RelayHelper: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "_relay", abstract: "ssh ProxyCommand: reach a guest through its host relay",
    shouldDisplay: false)
  @Option var descriptor: String

  func run() throws {
    do {
      let code = try RelayDescriptor.load(path: descriptor).connect()
      if code != 0 { throw ExitCode(code) }
    } catch let error as CIError {
      Output.note(error.description)
      throw ExitCode(1)
    }
  }
}

/// A repository option resolved against the current directory (default:
/// the current directory itself); the controller requires absolute paths.
func absolutePath(_ path: String?) -> String {
  let cwd = FileManager.default.currentDirectoryPath
  guard let path else { return cwd }
  return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true))
    .standardizedFileURL.path
}
