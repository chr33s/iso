import ArgumentParser
import Foundation
import IsoSandboxCore

/// `iso-sandbox macos …`: macOS guests (docs/design/macos-guest-computer-use.md).
struct MacOSCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "macos", abstract: "macOS guests with computer use.",
    subcommands: [
      MacTemplateCommand.self, MacCreate.self, MacStart.self, MacRun.self, MacStop.self,
      MacInspect.self, MacList.self, MacDelete.self, MacReconcile.self, MacCU.self,
    ])
}

struct MacTemplateCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "template", abstract: "Build and list macOS templates.",
    subcommands: [Build.self, ListTemplates.self, DeleteTemplate.self])

  struct Build: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Install macOS from a restore image, provision it, and publish a template.")
    @OptionGroup var root: RootOptions
    @Option(help: "macOS restore image (.ipsw)") var ipsw: String
    @Option(help: "Template name") var name: String
    @Option(help: "iso-macos-helper binary to install in the guest (default: beside iso-sandbox)")
    var helper: String?
    @Option(help: "Script run as root in the guest after setup, before the template is sealed")
    var provision: String?
    @Option var cpus = 4
    @Option var memoryMib: UInt64 = 8192
    @Option var diskGib: UInt64 = 64
    func run() async throws {
      let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
      let helper =
        helper.map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: exe).deletingLastPathComponent().appendingPathComponent(
          "iso-macos-helper")
      try printJSON(
        try await MacTemplates.build(
          root: try root.resolve(), name: try SandboxID(name), ipsw: URL(fileURLWithPath: ipsw),
          helper: helper, provision: provision.map { URL(fileURLWithPath: $0) }, executable: exe,
          cpus: cpus,
          memoryBytes: try bytes(memoryMib, mib), diskBytes: try bytes(diskGib, gib)))
    }
  }

  struct DeleteTemplate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete")
    @OptionGroup var root: RootOptions
    @Argument var name: String
    func run() async throws {
      try MacTemplates.delete(root: try root.resolve(), name: try SandboxID(name))
    }
  }

  struct ListTemplates: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list")
    @OptionGroup var root: RootOptions
    func run() async throws { try printJSON(MacTemplates.list(root: try root.resolve())) }
  }
}

struct MacCreate: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "create", abstract: "Clone a template into a stopped macOS sandbox.")
  @OptionGroup var root: RootOptions
  @Argument var id: String
  @Option var template: String
  @Option(help: "Ownership tag; `delete` requires it to match") var owner: String
  @Option var cpus = 4
  @Option var memoryMib: UInt64 = 8192
  @Option(help: "shared or host-only") var network = "shared"
  @Option(help: "ssh-ed25519 public key authorized for the guest user at first boot")
  var authorizedKey: String

  func validate() throws {
    guard ["shared", "host-only"].contains(network) else {
      throw ValidationError("--network must be shared or host-only")
    }
  }

  func run() async throws {
    try printJSON(
      try await MacSandboxes.create(
        root: try root.resolve(), id: try SandboxID(id), owner: owner,
        template: try SandboxID(template), cpus: cpus, memoryBytes: try bytes(memoryMib, mib),
        network: network == "host-only" ? .hostOnly : .shared, authorizedKey: authorizedKey))
  }
}

struct MacStart: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "start", abstract: "Boot a macOS sandbox under launchd.")
  @OptionGroup var root: RootOptions
  @Argument var id: String
  @Option var waitSeconds = 300
  @Option(help: "End the session at this host time (Unix seconds)") var expiresAt: Int64?
  func run() async throws {
    let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
    try printJSON(
      try await MacSandboxes.start(
        root: try root.resolve(), id: try SandboxID(id), executable: exe,
        wait: TimeInterval(waitSeconds),
        expiresAt: expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }))
  }
}

/// The launchd owner. Synchronous: it runs the AppKit main loop (see `Entry`).
struct MacRun: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "run", abstract: "Own a macOS VM (launchd runs this).", shouldDisplay: false)
  @OptionGroup var root: RootOptions
  @Argument var id: String
  func run() throws {
    let r = try root.resolve()
    let sandboxID = try SandboxID(id)
    do {
      try MainActor.assumeIsolated { try MacOwner.run(root: r, id: sandboxID) }
    } catch {
      // Exit 0 so launchd does not respawn a configuration error.
      try? Data("\(error)".utf8).write(to: r.macSandbox(sandboxID).ownerFailed, options: .atomic)
      FileHandle.standardError.write(Data("owner failed: \(error)\n".utf8))
    }
  }
}

struct MacStop: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "stop", abstract: "Stop gracefully and wait for the owner to exit.")
  @OptionGroup var root: RootOptions
  @Argument var id: String
  @Option var timeoutSeconds = 400
  func run() async throws {
    let path = try await MacSandboxes.stop(
      root: try root.resolve(), id: try SandboxID(id), timeout: TimeInterval(timeoutSeconds))
    try printJSON(["stopPath": path])
  }
}

struct MacInspect: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "inspect")
  @OptionGroup var root: RootOptions
  @Argument var id: String
  func run() async throws {
    try printJSON(try MacSandboxes.inspect(root: try root.resolve(), id: try SandboxID(id)))
  }
}

struct MacList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "list")
  @OptionGroup var root: RootOptions
  func run() async throws { try printJSON(try MacSandboxes.list(root: try root.resolve())) }
}

struct MacDelete: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "delete")
  @OptionGroup var root: RootOptions
  @Argument var id: String
  @Option var owner: String
  func run() async throws {
    try await MacSandboxes.delete(root: try root.resolve(), id: try SandboxID(id), owner: owner)
  }
}

struct MacReconcile: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "reconcile")
  @OptionGroup var root: RootOptions
  func run() async throws { try printJSON(try MacSandboxes.reconcile(root: try root.resolve())) }
}

/// Computer use against a running macOS sandbox.
struct MacCU: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "cu", abstract: "Computer use: sessions, frames, actions.",
    subcommands: [Session.self, Frame.self, Act.self])

  static func check(_ r: MacControlResponse) throws -> MacControlResponse {
    guard r.ok else { throw SandboxError(r.error ?? "refused") }
    return r
  }

  struct SessionOutput: Encodable {
    var session: String
    var binding: CUBinding
  }

  struct Session: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open a session bound to this boot.")
    @OptionGroup var root: RootOptions
    @Argument var id: String
    func run() async throws {
      let r = try check(
        try MacSandboxes.cu(root: try root.resolve(), id: try SandboxID(id), .init(op: .cuSession)))
      guard let s = r.session, let b = r.binding else { throw SandboxError("no session") }
      try printJSON(SessionOutput(session: s, binding: b))
    }
  }

  struct FrameOutput: Encodable {
    var frameId: String
    var seq: Int
    var width: Int
    var height: Int
    var bootId: String
    var guestBoot: String
    var vmInstance: String
    var sha256: String
    var timestamp: Date
    var path: String
  }

  struct Frame: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Capture a frame (PNG, framebuffer pixels) to --out.")
    @OptionGroup var root: RootOptions
    @Argument var id: String
    @Option var session: String
    @Option(help: "Where to write the PNG") var out: String
    func run() async throws {
      let r = try check(
        try MacSandboxes.cu(
          root: try root.resolve(), id: try SandboxID(id), .init(op: .cuFrame, session: session)))
      guard let f = r.frame else { throw SandboxError("no frame") }
      let url = URL(fileURLWithPath: out)
      try f.png.write(to: url, options: .atomic)
      try printJSON(
        FrameOutput(
          frameId: f.frameId, seq: f.seq, width: f.width, height: f.height, bootId: f.bootId,
          guestBoot: f.guestBoot, vmInstance: f.vmInstance, sha256: f.sha256,
          timestamp: f.timestamp,
          path: url.path))
    }
  }

  struct Act: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract:
        "Submit one action, given as JSON (kind, x, y, button, count, path, dx, dy, keyCode, modifiers, text)."
    )
    @OptionGroup var root: RootOptions
    @Argument var id: String
    @Option var session: String
    @Option(help: "The action as a JSON object") var action: String
    @Option(help: "Refuse unless this frame came from the session's current binding")
    var basedOnFrame: String?
    func run() async throws {
      let request = try JSONDecoder().decode(CUActionRequest.self, from: Data(action.utf8))
      let r = try check(
        try MacSandboxes.cu(
          root: try root.resolve(), id: try SandboxID(id),
          .init(op: .cuAct, session: session, action: request, basedOnFrame: basedOnFrame)))
      try printJSON(["submitted": r.submitted ?? 0])
    }
  }
}

/// `count * unit`, refusing overflow instead of trapping.
func bytes(_ count: UInt64, _ unit: UInt64) throws -> UInt64 {
  let (v, overflow) = count.multipliedReportingOverflow(by: unit)
  guard !overflow else { throw ValidationError("size \(count) is too large") }
  return v
}
