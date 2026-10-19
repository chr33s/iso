import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost

/// A usage error raised while the command runs (exit 2, `INVALID_ARGUMENT`).
private typealias Invalid = IsoCore.ValidationError

// MARK: - audit

struct Audit: MachineCommand, StreamCommand {
  static let configuration = CommandConfiguration(
    abstract:
      "Show recorded boundary events and invocation history (metadata only, never values)",
    discussion: """
      Without --runs or --run: the instance's boundary events.
      --runs lists recorded invocations (`iso run`, `claude`, `codex`,
      `claude-agents`), newest first, including deleted instances' runs;
      a NAME filters by the recorded instance name. --run ID shows one
      invocation's summary and ordered timeline, including the VM context of
      its exact boot.

      --output json prints one bounded iso.machine/v1 page and --output jsonl
      one page of iso.audit.stream/v1 lines; neither drains every page. --follow
      keeps reading new records (text or jsonl) until interrupted; it does not
      stop when the agent's transport exits. --export writes the full retained
      snapshot of one run to a new file. "Transport exited 0" is the
      transport's status, never a verdict on the task. See docs/audit.md.
      """)

  @OptionGroup var global: GlobalOptions
  @Argument(
    help: "Instance name (required if multiple instances exist; with --runs, a filter)",
    transform: parseInstanceName)
  var name: InstanceName?
  @Flag(help: "Print an advisory JSONC fragment that narrows what was observed")
  var suggestConfig = false
  @Flag(help: "List recorded invocations, newest first") var runs = false
  @Option(
    name: .customLong("run"),
    help: ArgumentHelp("Show one invocation's summary and timeline", valueName: "ID"))
  var runID: String?
  @Flag(help: "With --run, keep reading new records until interrupted") var follow = false
  @Option(
    help: ArgumentHelp(
      "Continue from the cursor of an earlier page or follow stream", valueName: "CURSOR"))
  var after: String?
  @Option(
    help: ArgumentHelp(
      "Records per page (default \(AuditReader.defaultLimit), at most \(AuditReader.maxLimit))",
      valueName: "N"))
  var limit: Int?
  @Option(
    help: ArgumentHelp(
      "With --run, write its full retained snapshot to a new file (never overwrites)",
      valueName: "PATH"))
  var export: String?

  /// Exactly one of the three selections, with its mode.
  enum View: Equatable {
    case instance(InstanceName?, suggestConfig: Bool)
    case runs(InstanceName?)
    case run(AuditRunID, Mode)
  }

  enum Mode: Equatable {
    case page
    case follow
    case export(String)
  }

  /// Validated while the command runs, so machine and stream modes report
  /// a usage error in their own format.
  func view() throws -> View {
    let output = global.output
    if runs && runID != nil { throw Invalid("--runs cannot be combined with --run") }
    if suggestConfig && (runs || runID != nil) {
      throw Invalid("--suggest-config applies to the instance view only")
    }
    if (follow || export != nil) && runID == nil {
      throw Invalid("--\(follow ? "follow" : "export") requires --run")
    }
    if follow && export != nil {
      throw Invalid("--follow cannot be combined with --export")
    }
    if follow && output == .json {
      throw Invalid("--follow streams text or --output jsonl, not --output json")
    }
    if export != nil && output != .text {
      throw Invalid("--export writes its own file; it cannot be combined with --output")
    }
    if export != nil && (after != nil || limit != nil) {
      throw Invalid("--export reads the whole snapshot; --after and --limit do not apply")
    }
    if let limit, !(1...AuditReader.maxLimit).contains(limit) {
      throw Invalid("--limit must be between 1 and \(AuditReader.maxLimit)")
    }
    if let runID {
      if name != nil {
        throw Invalid("--run selects one invocation; it takes no instance name")
      }
      let id = try AuditRunID(runID)
      return .run(id, export.map(Mode.export) ?? (follow ? .follow : .page))
    }
    if runs { return .runs(name) }
    if after != nil || limit != nil {
      throw Invalid("--after and --limit apply to --runs and --run")
    }
    if output != .text {
      throw Invalid("--output \(output.rawValue) requires --runs or --run")
    }
    return .instance(name, suggestConfig: suggestConfig)
  }

  func cursor() throws(AuditReadError) -> AuditCursor? {
    try after.map { text throws(AuditReadError) in try AuditCursor(token: text) }
  }

  var pageLimit: Int { limit ?? AuditReader.defaultLimit }

  func run() throws {
    switch global.output {
    case .json:
      try IsoCLI.run(global, Self.self) { try machinePage() }
    case .jsonl:
      try IsoCLI.run { try stream() }
    case .text:
      try IsoCLI.run { try text() }
    }
  }

  static func reader(_ global: GlobalOptions) throws -> AuditReader {
    // Reads audit data only: no secret store, update check or runtime.
    let context = try CommandContext.load(global, intent: .preview)
    return AuditReader(store: AuditStore(config: context.config))
  }

  func machinePage() throws -> MachineAuditPage {
    let selection: AuditSelection
    switch try view() {
    case .runs(let instance): selection = .runs(instance: instance)
    case .run(let id, _): selection = .run(id)
    case .instance: throw Invalid("--output json requires --runs or --run")
    }
    return MachineAuditPage(
      try Self.reader(global).page(selection, after: try cursor(), limit: pageLimit))
  }

  func stream() throws {
    let writer = AuditStreamWriter(emit: MachineSession.emitLine)
    do {
      let view = try view()
      let reader = try Self.reader(global)
      switch view {
      case .runs(let instance):
        try writer.page(reader, .runs(instance: instance), after: try cursor(), limit: pageLimit)
      case .run(let id, .page):
        try writer.page(reader, .run(id), after: try cursor(), limit: pageLimit)
      case .run(let id, .follow):
        try writer.follow(reader, id, after: try cursor(), limit: pageLimit)
      case .run(_, .export), .instance:
        throw Invalid("--output jsonl requires --runs or --run")
      }
    } catch {
      writer.fail(error)
      throw error
    }
  }

  func text() throws {
    let output = StandardStreams()
    switch try view() {
    case .instance(let name, let suggest):
      let context = try CommandContext.load(global)
      let instance = try InstanceStore.resolve(context.config, name: name)
      let lines = try BoundaryAudit.lines(instance)
      let events = BoundaryAudit.events(from: lines)
      if suggest {
        BoundaryAudit.suggestConfig(events).forEach(context.output.out)
        return
      }
      if events.isEmpty {
        context.output.error("No boundary events recorded for '\(instance.name)' yet.")
      }
      for line in lines {
        context.output.out(neutralizeControls(line))
      }
    case .runs(let instance):
      let page = try Self.reader(global).page(
        .runs(instance: instance), after: try cursor(), limit: pageLimit)
      AuditText.listing(page, instance: instance).forEach(output.out)
    case .run(let id, .page):
      let page = try Self.reader(global).page(.run(id), after: try cursor(), limit: pageLimit)
      AuditText.detail(page).forEach(output.out)
    case .run(let id, .follow):
      try AuditText.follow(
        try Self.reader(global), id, after: try cursor(), limit: pageLimit, out: output.out)
    case .run(let id, .export(let path)):
      let exported = try AuditExport.write(try Self.reader(global), id, to: path)
      output.error(
        "Exported \(exported.events) event(s) of \(id) (snapshot through sequence \(exported.head)) to \(path)"
      )
    }
  }
}

// MARK: - Machine page

/// `audit --output json`: one bounded page. `next_cursor` is null exactly
/// when the selected snapshot is exhausted.
struct MachineAuditPage: Encodable {
  let page: AuditPage

  init(_ page: AuditPage) { self.page = page }

  enum CodingKeys: String, CodingKey {
    case selection, coverage, run, events, runs
    case asOf = "as_of"
    case nextCursor = "next_cursor"
  }

  func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(page.selection.json, forKey: .selection)
    try values.encode(page.asOf, forKey: .asOf)
    try values.encode(page.coverage, forKey: .coverage)
    try values.encode(page.nextCursor?.token, forKey: .nextCursor)
    switch page.selection {
    case .runs:
      try values.encode(page.items, forKey: .runs)
    case .run:
      try values.encode(page.run, forKey: .run)
      try values.encode(page.items, forKey: .events)
    }
  }
}

// MARK: - JSONL

/// The `iso.audit.stream/v1` writer: one compact object and LF per record,
/// each written whole and unbuffered. After a failed write nothing more is
/// written, not even an error record.
final class AuditStreamWriter {
  let emit: ([UInt8]) throws -> Void
  private(set) var broken = false

  init(emit: @escaping ([UInt8]) throws -> Void) { self.emit = emit }

  func line(_ type: String, _ members: [(String, OutputJSON)]) throws {
    let value = OutputJSON.object(
      [("schema", .string(AuditJSONL.schema)), ("type", .string(type))] + members)
    let bytes = Array((value.compactRendered() + "\n").utf8)
    guard bytes.count <= AuditJSONL.lineBytes else { throw AuditReadError.recordTooLarge }
    do { try emit(bytes) } catch {
      broken = true
      throw error
    }
  }

  func state(_ page: AuditPage, mode: String) throws {
    var members: [(String, OutputJSON)] = [
      ("selection", page.selection.json), ("mode", .string(mode)),
      ("as_of", try auditJSON(page.asOf)), ("coverage", try auditJSON(page.coverage)),
    ]
    if let run = page.run { members.append(("run", try auditJSON(run))) }
    try line("state", members)
  }

  func event(_ relationship: AuditRelationship, _ event: AuditEvent) throws {
    try line(
      "event", [("relationship", .string(relationship.rawValue)), ("event", try auditJSON(event))])
  }

  func progress(_ page: AuditPage, cursor: AuditCursor?) throws {
    try line(
      "progress",
      [
        ("as_of", try auditJSON(page.asOf)), ("snapshot_exhausted", .bool(page.exhausted)),
        ("cursor", .optional(cursor?.token)),
      ])
  }

  /// A finite page: state, its items, then progress whose cursor is the
  /// page's `next_cursor` (null only at exhaustion).
  func page(
    _ reader: AuditReader, _ selection: AuditSelection, after: AuditCursor?, limit: Int
  ) throws {
    let page = try reader.page(
      selection, after: after, limit: limit, byteBudget: AuditReader.pageBytes - controlReserve)
    try state(page, mode: "page")
    for item in page.items {
      switch item {
      case .event(let relationship, let event): try self.event(relationship, event)
      case .run(let view): try line("run", [("run", try auditJSON(view))])
      }
    }
    try progress(page, cursor: page.nextCursor)
  }

  /// Room for the state and progress records inside the page byte budget.
  let controlReserve = 2 * AuditJSONL.lineBytes

  /// Drains every page at the current `H`, then polls for a newer one.
  /// A snapshot whose `H` did not move emits nothing; one that did emits
  /// state, its new events and progress even when no event matched.
  func follow(
    _ reader: AuditReader, _ id: AuditRunID, after: AuditCursor?, limit: Int,
    poll: Duration = .milliseconds(500), until stop: () -> Bool = { false }
  ) throws {
    try reader.follow(
      id, after: after, limit: limit, byteBudget: AuditReader.pageBytes - controlReserve,
      poll: poll, until: stop, snapshot: { try state($0, mode: "follow") },
      page: { page, fresh, cursor in
        for (relationship, event) in fresh { try self.event(relationship, event) }
        try progress(page, cursor: cursor)
      })
  }

  /// A terminal error record, only at an intact line boundary.
  func fail(_ error: any Error) {
    guard !broken else { return }
    let (code, bounds) = Self.classify(error)
    try? line(
      "error",
      [
        ("code", .string(code)),
        ("message", .string(MachineFailure.bounded(neutralizeControls(oneLine(error))))),
        ("bounds", bounds.flatMap { try? auditJSON($0) } ?? .null),
      ])
  }

  static func classify(_ error: any Error) -> (String, AuditBounds?) {
    switch error {
    case let audit as AuditReadError: (audit.code, audit.bounds)
    case is IsoCore.ValidationError, is ArgumentParser.ValidationError: ("invalid_argument", nil)
    default: ("failed", nil)
    }
  }
}

// MARK: - Export

enum AuditExport {
  /// Drains one fixed snapshot into a private temporary file beside `path`
  /// and links it into place only after exhaustion, refusing to overwrite.
  /// An expired cursor or read failure leaves no file behind.
  static func write(
    _ reader: AuditReader, _ id: AuditRunID, to path: String, limit: Int = AuditReader.maxLimit
  ) throws -> (
    events: Int, head: UInt64
  ) {
    try write(to: path) { page in try reader.pages(.run(id), limit: limit, page) }
  }

  /// `pages` hands every page of one fixed snapshot, in order, to its
  /// argument.
  static func write(
    to path: String, pages: ((AuditPage) throws -> Void) throws -> Void
  ) throws -> (events: Int, head: UInt64) {
    var existing = stat()
    if lstat(path, &existing) == 0 {
      throw HostError("\(path) already exists; --export never overwrites")
    }
    // A signal ends the drain through the error path, which removes the
    // temporary file; nothing partial is left beside PATH.
    let shutdown = Shutdown.install()
    defer { shutdown.restore() }
    let temporary = AtomicFile.temporaryPath(for: path)
    let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw HostError.posix("Failed to create", temporary) }
    defer { unlink(temporary) }
    var count = 0
    var head: UInt64?
    do {
      defer { close(fd) }
      try Shutdown.check()
      try pages { page in
        try Shutdown.check()
        if head == nil {
          head = page.asOf.sequence
          let header = OutputJSON.object([
            ("schema", .string(AuditStore.schema)), ("selection", page.selection.json),
            ("as_of", try auditJSON(page.asOf)), ("coverage", try auditJSON(page.coverage)),
            ("run", try auditJSON(page.run)), ("snapshot_exhausted", .bool(true)),
          ]).compactRendered()
          try AtomicFile.writeAll(fd, Array((header.dropLast() + ",\"events\":[").utf8), temporary)
        }
        for item in page.items {
          let json = try JSONOutput.render(item, pretty: false)
          try AtomicFile.writeAll(fd, Array(((count == 0 ? "" : ",") + json).utf8), temporary)
          count += 1
        }
      }
      try AtomicFile.writeAll(fd, Array("]}\n".utf8), temporary)
      guard fsync(fd) == 0 else { throw HostError.posix("Failed to sync", temporary) }
    }
    guard link(temporary, path) == 0 else {
      if errno == EEXIST { throw HostError("\(path) already exists; --export never overwrites") }
      throw HostError.posix("Failed to create", path)
    }
    return (count, head ?? 0)
  }
}

// MARK: - Text

/// Every line is passed through `clean` once, at the end, so a stored string
/// never reaches the terminal raw.
enum AuditText {
  static func listing(_ page: AuditPage, instance: InstanceName?) -> [String] {
    var lines: [String] = []
    let runs = page.items.compactMap { item -> AuditRunView? in
      if case .run(let view) = item { return view }
      return nil
    }
    if runs.isEmpty {
      lines.append(
        instance.map { "No recorded runs for '\($0)'." } ?? "No recorded runs.")
    } else {
      lines.append(
        padded("RUN", 37) + " " + padded("STARTED", 21) + " " + padded("COMMAND", 18) + " "
          + padded("INSTANCE", 16) + " OUTCOME")
      for view in runs {
        let summary = view.summary
        lines.append(
          padded(summary.auditRunID.rawValue, 37) + " " + padded(summary.startedAt, 21) + " "
            + padded(command(summary), 18) + " " + padded(summary.instanceName ?? "-", 16) + " "
            + summary.outcome.text)
      }
    }
    if let cursor = page.nextCursor {
      let filter = instance.map { "\($0.rawValue) " } ?? ""
      lines.append("More runs: iso audit \(filter)--runs --after '\(cursor.token)'")
    }
    lines += coverageNotes(page.coverage)
    return lines.map(clean)
  }

  static func command(_ summary: AuditRunSummary) -> String {
    let request = summary.request.fact
    let agent = request.command == .run ? " " + (request.requestedAgent ?? "?") : ""
    return request.command.rawValue + agent
  }

  static func detail(_ page: AuditPage) -> [String] {
    guard let view = page.run else { return [] }
    var lines = summary(view, coverage: page.coverage)
    lines.append("Timeline:")
    let events = page.items.compactMap { item -> (AuditRelationship, AuditEvent)? in
      if case .event(let relationship, let event) = item { return (relationship, event) }
      return nil
    }
    if events.isEmpty { lines.append("  (no retained events in this page)") }
    lines += events.map(eventLine)
    if let cursor = page.nextCursor {
      lines.append(
        "More events: iso audit --run \(view.summary.auditRunID) --after '\(cursor.token)'")
    }
    return lines.map(clean)
  }

  static func summary(_ view: AuditRunView, coverage: AuditCoverage) -> [String] {
    let run = view.summary
    let request = run.request.fact
    var lines = ["Run \(run.auditRunID)"]
    lines.append(
      "  Command:     iso \(request.command.rawValue) (\(request.role.rawValue), \(request.lifecycle.rawValue)\(request.permissionMode.map { ", \($0.rawValue)" } ?? ""))"
    )
    lines.append("  Started:     \(run.startedAt)")
    if let environment = run.environment?.fact {
      if let agent = environment.agent {
        let contract = agent.adapterContractVersion.map { " v\($0)" } ?? ""
        lines.append(
          "  Agent:       \(agent.definitionID) (adapter \(agent.adapterID)\(contract), \(agent.source?.rawValue ?? "unknown"))"
        )
      }
      let identity = [
        environment.vmID.map { "vm \($0.rawValue.prefix(12))" },
        environment.bootID.map { "boot \($0.rawValue.prefix(12))" } ?? "boot unknown",
      ].compactMap { $0 }.joined(separator: ", ")
      lines.append(
        "  Instance:    \(environment.instanceName) (\(environment.action.rawValue); \(identity))")
      lines.append("  Image:       \(environment.image) (\(environment.guestOS))")
      lines.append("  Workspace:   \(environment.workspace.rawValue)")
      let egress = environment.egress.map { "\($0.mode) (\($0.transport))" } ?? "not recorded"
      lines.append(
        "  Egress:      \(egress); requested \(environment.requested.egress)")
      let proxied =
        environment.proxiedProviders.isEmpty
        ? "none" : environment.proxiedProviders.joined(separator: ", ")
      lines.append(
        "  Proxy:       \(environment.requested.proxyMode) requested; proxied: \(proxied)")
      let policy =
        environment.policy.map { "\($0.mode)\($0.digest.map { " \($0.prefix(19))" } ?? "")" }
        ?? "no boot binding"
      lines.append("  Policy:      \(policy)")
      if let ttl = environment.requested.sessionTTLSeconds {
        lines.append("  Session TTL: \(ttl)s requested")
      }
      if !environment.unreadable.isEmpty {
        lines.append(
          "  Unreadable:  \(environment.unreadable.joined(separator: ", ")) (fields above unknown)")
      }
    } else {
      lines.append("  Environment: not recorded")
    }
    if let handoff = run.handoff?.fact {
      let names =
        handoff.forwardedVariables.isEmpty
        ? "none" : handoff.forwardedVariables.joined(separator: ", ")
      lines.append(
        "  Handoff:     \(handoff.transport)\(handoff.pty ? " with a terminal" : ""); forwarded names: \(names)"
      )
    }
    lines.append("  Outcome:     \(run.outcome.text)")
    for cleanup in run.cleanup {
      let linked = cleanup.relationship == .linkedOperation ? " by run-cleanup" : ""
      lines.append(
        "  Cleanup:     \(cleanup.outcome.rawValue)\(linked) (session \(cleanup.sessionID.rawValue.prefix(12)), \(cleanup.event.recordedAt))"
      )
    }
    if !view.openerRetained {
      lines.append("  Detail:      earlier events of this run were retired by retention")
    }
    lines += coverageNotes(coverage)
    return lines
  }

  static func coverageNotes(_ coverage: AuditCoverage) -> [String] {
    var lines: [String] = []
    let unsupported = coverage.sources.filter { $0.status == .unsupported }.map(\.source)
    var notes = "Coverage: host launch and boundary records"
    if coverage.sources.contains(where: { $0.status == .unavailable }) {
      notes += " (capture currently unavailable)"
    }
    if !unsupported.isEmpty {
      notes +=
        "; not observed: "
        + unsupported.joined(separator: ", ").replacingOccurrences(of: "_", with: " ")
    }
    lines.append(notes)
    if coverage.vmContext == .unavailable {
      lines.append("  VM context: unavailable (no known boot identity)")
    }
    for gap in coverage.gaps {
      var text = "  Gap: \(gap.reason.rawValue.replacingOccurrences(of: "_", with: " "))"
      if let after = gap.afterSequence { text += " after #\(after)" }
      if let before = gap.beforeSequence { text += " before #\(before)" }
      if let since = gap.since { text += " since \(since)" }
      if let count = gap.refusedCount { text += " (\(count) refused)" }
      if gap.ongoing { text += " — ongoing" }
      lines.append(text)
    }
    let retained = coverage.retained
    if retained.checkpointThrough > 0 || retained.expiredRuns > 0 {
      var text = "  Retained: sequences after #\(retained.checkpointThrough)"
      if let at = retained.checkpointThroughRecordedAt {
        text += " (older detail retired; through \(at))"
      }
      if retained.expiredRuns > 0 { text += "; \(retained.expiredRuns) older run(s) expired" }
      lines.append(text)
    }
    return lines
  }

  static func eventLine(_ entry: (AuditRelationship, AuditEvent)) -> String {
    let (relationship, event) = entry
    let label =
      relationship == .vmContext
      ? "VM context" : relationship.rawValue.replacingOccurrences(of: "_", with: " ")
    let data = (try? auditJSON(event.data)) ?? .object([])
    return
      "  #\(event.sequence) \(event.recordedAt) \(padded(label, 16)) \(padded(event.kind.rawValue, 30)) \(event.evidence.rawValue)\(details(data))"
  }

  /// Scalar fields as `key=value`; nested values compact. Control
  /// characters never reach the terminal raw.
  static func details(_ data: OutputJSON) -> String {
    guard case .object(let members) = data, !members.isEmpty else { return "" }
    let parts = members.map { key, value -> String in
      let text: String
      switch value {
      case .string(let string): text = string
      case .array(let values):
        text = values.map { value in
          if case .string(let string) = value { return string }
          return value.compactRendered()
        }.joined(separator: ",")
      default: text = value.compactRendered()
      }
      return "\(key)=\(clean(text))"
    }
    return "  " + parts.joined(separator: " ")
  }

  /// One display line: control and format characters, newlines included,
  /// become `?`.
  static func clean(_ text: String) -> String {
    neutralizeControls(text).replacingOccurrences(of: "\n", with: "?")
      .replacingOccurrences(of: "\t", with: "?")
  }

  /// The human live view: the summary once, then each newly selected event
  /// once. Context that becomes known later (a boot) is shown when it does,
  /// marked by its relationship.
  static func follow(
    _ reader: AuditReader, _ id: AuditRunID, after: AuditCursor?, limit: Int,
    out: (String) -> Void, poll: Duration = .milliseconds(500), until stop: () -> Bool = { false }
  ) throws {
    var header = false
    try reader.follow(
      id, after: after, limit: limit, poll: poll, until: stop,
      snapshot: { page in
        guard !header, let view = page.run else { return }
        summary(view, coverage: page.coverage).map(clean).forEach(out)
        out("Timeline (following; Ctrl-C stops the viewer only):")
        header = true
      },
      page: { _, fresh, _ in fresh.map(eventLine).map(clean).forEach(out) })
  }
}
