import Foundation

/// The computer-use MCP server a guest agent runs (`iso-macos-helper
/// cu-mcp`; docs/design/guest-driven-computer-use.md §6): JSON-RPC 2.0 over
/// stdio, one message per line, mapped onto the vsock channel's requests.
/// The transport is injected, so the mapping is unit-testable.
package final class GuestCUMCP {
  package typealias Send = (GuestCURequest) throws -> GuestCUResponse

  private let send: Send
  private var session: String?
  /// Whether the host answers `wait`, learned from `status` once.
  private var supportsWait: Bool?

  package static let serverName = "iso-cu"
  package static let version = "1"
  /// Offered when the client asks for a version this server does not know.
  package static let protocolVersion = "2025-06-18"
  static let knownVersions: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18"]

  package init(send: @escaping Send) { self.send = send }

  // MARK: JSON-RPC

  /// One message line to its reply line; nil for a notification.
  package func handle(_ line: [UInt8]) -> Data? {
    guard let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
    else { return Self.reply(id: NSNull(), error: (-32700, "parse error")) }
    let id = message["id"]
    guard let method = message["method"] as? String else {
      return id.map { Self.reply(id: $0, error: (-32600, "invalid request")) }
    }
    // Notifications (no id) get no reply.
    guard let id else { return nil }
    let params = message["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
      let asked = params["protocolVersion"] as? String
      return Self.reply(
        id: id,
        result: [
          "protocolVersion": asked.flatMap { Self.knownVersions.contains($0) ? $0 : nil }
            ?? Self.protocolVersion,
          "capabilities": ["tools": ["listChanged": false]],
          "serverInfo": ["name": Self.serverName, "version": Self.version],
        ])
    case "ping":
      return Self.reply(id: id, result: [:])
    case "tools/list":
      return Self.reply(id: id, result: ["tools": Self.tools])
    case "tools/call":
      guard let name = params["name"] as? String else {
        return Self.reply(id: id, error: (-32602, "tools/call needs a name"))
      }
      return Self.reply(id: id, result: call(name, params["arguments"] as? [String: Any] ?? [:]))
    default:
      return Self.reply(id: id, error: (-32601, "method not found: \(method)"))
    }
  }

  static func reply(id: Any, result: [String: Any]) -> Data {
    line(["jsonrpc": "2.0", "id": id, "result": result])
  }

  static func reply(id: Any, error: (Int, String)) -> Data {
    line(["jsonrpc": "2.0", "id": id, "error": ["code": error.0, "message": error.1]])
  }

  private static func line(_ object: [String: Any]) -> Data {
    var d = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    d.append(0x0A)
    return d
  }

  // MARK: tools

  private static func schema(_ properties: [String: Any], required: [String]) -> [String: Any] {
    [
      "type": "object", "properties": properties, "required": required,
      "additionalProperties": false,
    ]
  }

  private static var coordinate: [String: Any] {
    [
      "type": "number", "description": "Framebuffer pixels from the top-left (1920×1200)",
    ]
  }
  private static var frameId: [String: Any] {
    [
      "type": "string", "description": "The frameId of the screenshot this action is based on",
    ]
  }
  private static var button: [String: Any] {
    [
      "type": "string", "enum": ["left", "right", "middle"],
    ]
  }
  private static var settle: [String: Any] {
    [
      "type": "integer", "minimum": 0, "maximum": GuestCUProtocol.Wait.idleMs.upperBound,
      "description":
        "After the action, wait until the screen has been quiet this long (ms; 0, or 50-2000; default \(GuestCUProtocol.Wait.defaultIdleMs)). A blinking caret toggles about every 500 ms, so values of 500 or more may not settle.",
    ]
  }

  /// An action tool's input schema, with `settle_ms` added.
  private static func actionSchema(_ properties: [String: Any], required: [String])
    -> [String: Any]
  {
    schema(properties.merging(["settle_ms": settle]) { a, _ in a }, required: required)
  }

  package static var tools: [[String: Any]] {
    [
      [
        "name": "screenshot",
        "description":
          "Capture this VM's display. Returns the image and the frameId every action must name.",
        "inputSchema": schema([:], required: []),
      ],
      [
        "name": "control_status",
        "description":
          "Who drives the display (idle, guest or host) and how long a host hold lasts.",
        "inputSchema": schema([:], required: []),
      ],
      [
        "name": "click",
        "description": "Click at a point.",
        "inputSchema": actionSchema(
          [
            "x": coordinate, "y": coordinate, "button": button,
            "count": ["type": "integer", "minimum": 1, "maximum": 3], "frameId": frameId,
          ], required: ["x", "y", "frameId"]),
      ],
      [
        "name": "move",
        "description": "Move the pointer.",
        "inputSchema": actionSchema(
          ["x": coordinate, "y": coordinate, "frameId": frameId], required: ["x", "y", "frameId"]),
      ],
      [
        "name": "drag",
        "description": "Press, move along a path of 2-1000 points, release.",
        "inputSchema": actionSchema(
          [
            "path": [
              "type": "array", "minItems": 2, "maxItems": 1000,
              "items": schema(["x": coordinate, "y": coordinate], required: ["x", "y"]),
            ],
            "button": button, "frameId": frameId,
          ], required: ["path", "frameId"]),
      ],
      [
        "name": "scroll",
        "description": "Scroll at a point by dx, dy pixels.",
        "inputSchema": actionSchema(
          [
            "x": coordinate, "y": coordinate, "dx": ["type": "integer"], "dy": ["type": "integer"],
            "frameId": frameId,
          ], required: ["x", "y", "frameId"]),
      ],
      [
        "name": "key",
        "description": "Press one key (macOS virtual key code 0-127) with modifiers.",
        "inputSchema": actionSchema(
          [
            "keyCode": ["type": "integer", "minimum": 0, "maximum": 127],
            "modifiers": [
              "type": "array",
              "items": ["type": "string", "enum": ["shift", "control", "option", "command"]],
            ],
            "frameId": frameId,
          ], required: ["keyCode", "frameId"]),
      ],
      [
        "name": "type",
        "description": "Type printable ASCII text (and \\n, \\t) on a US keyboard layout.",
        "inputSchema": actionSchema(
          ["text": ["type": "string", "maxLength": 4096], "frameId": frameId],
          required: ["text", "frameId"]),
      ],
      [
        "name": "wait_for_screen",
        "description":
          "Wait until the screen (or a region) has settled, then return a screenshot. Video, spinners and other content that never settles ends in a timeout; narrow the region or take the screenshot anyway.",
        "inputSchema": schema(
          [
            "since": [
              "type": "integer", "minimum": 0,
              "description":
                "A damageSeq from an earlier screenshot or action: changes after it count (default: now)",
            ],
            "idle_ms": [
              "type": "integer", "minimum": GuestCUProtocol.Wait.idleMs.lowerBound,
              "maximum": GuestCUProtocol.Wait.idleMs.upperBound,
              "description":
                "Quiet time that counts as settled (default \(GuestCUProtocol.Wait.defaultIdleMs)). A blinking caret toggles about every 500 ms.",
            ],
            "timeout_ms": [
              "type": "integer", "minimum": GuestCUProtocol.Wait.timeoutMs.lowerBound,
              "maximum": GuestCUProtocol.Wait.timeoutMs.upperBound,
              "description":
                "Give up after this long (default \(GuestCUProtocol.Wait.defaultTimeoutMs))",
            ],
            "until": [
              "type": "string", "enum": ["change", "idle"],
              "description":
                "change (default): wait for a change after since, then quiet; idle: return once quiet, even with no change",
            ],
            "region": schema(
              [
                "x": ["type": "integer", "minimum": 0], "y": ["type": "integer", "minimum": 0],
                "width": ["type": "integer", "minimum": 1],
                "height": ["type": "integer", "minimum": 1],
              ], required: ["x", "y", "width", "height"]),
            "include_screenshot": [
              "type": "boolean", "description": "Return a screenshot afterwards (default true)",
            ],
          ], required: []),
      ],
    ]
  }

  private struct ToolError: Error { var message: String }

  private func call(_ name: String, _ args: [String: Any]) -> [String: Any] {
    do {
      return try run(name, args)
    } catch let e as ToolError {
      return ["content": [["type": "text", "text": e.message]], "isError": true]
    } catch {
      return [
        "content": [["type": "text", "text": "computer use is unavailable: \(error)"]],
        "isError": true,
      ]
    }
  }

  private func run(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
    switch name {
    case "screenshot":
      let r = try withSession { GuestCURequest(op: .frame, session: $0) }
      return ["content": try Self.screenshot(r)]
    case "control_status":
      let r = try checked(try send(GuestCURequest(op: .status)))
      return text(
        "controller: \(r.controller?.rawValue ?? "unknown"), hold remaining: \(r.holdRemainingSeconds ?? 0) s"
      )
    case "click", "move", "drag", "scroll", "key", "type":
      let action = try Self.action(name, args)
      guard let frame = args["frameId"] as? String else {
        throw ToolError(message: "\(name) needs the frameId of the screenshot it is based on")
      }
      let settle = try Self.settleMs(args)
      let r = try withSession {
        GuestCURequest(op: .act, session: $0, action: action, basedOnFrame: frame)
      }
      var report = "submitted \(r.submitted ?? 0) input events (submission, not proof of delivery)"
      // An older host sends no damageSeq and has no `wait`.
      if settle > 0, let since = r.damageSeq {
        report += "; " + settled(since: since, idleMs: settle)
      }
      return text(report)
    case "wait_for_screen":
      return try waitForScreen(args)
    default:
      throw ToolError(message: "unknown tool \(name)")
    }
  }

  private func text(_ s: String) -> [String: Any] { ["content": [["type": "text", "text": s]]] }

  /// A frame response as MCP content: the image, then its frameId and damageSeq.
  static func screenshot(_ r: GuestCUResponse) throws -> [[String: Any]] {
    guard let f = r.frame else { throw ToolError(message: "no frame") }
    let seq = r.damageSeq.map { ", damageSeq: \($0)" } ?? ""
    return [
      ["type": "image", "data": f.png.base64EncodedString(), "mimeType": "image/png"],
      [
        "type": "text",
        "text": "frameId: \(f.frameId) (\(f.width)×\(f.height) pixels, origin top-left)\(seq)",
      ],
    ]
  }

  /// `settle_ms`: 0 turns settling off; otherwise a `wait` quiet time.
  static func settleMs(_ args: [String: Any]) throws -> Int {
    guard let value = args["settle_ms"] else { return GuestCUProtocol.Wait.defaultIdleMs }
    guard let n = Self.integer(value), n == 0 || GuestCUProtocol.Wait.idleMs.contains(n) else {
      throw ToolError(
        message:
          "settle_ms must be 0 or \(GuestCUProtocol.Wait.idleMs.lowerBound)-\(GuestCUProtocol.Wait.idleMs.upperBound)"
      )
    }
    return n
  }

  /// A JSON number that is a whole integer; nil for anything else.
  static func integer(_ value: Any?) -> Int? {
    guard let n = value as? NSNumber, !isBoolean(n) else { return nil }
    let d = n.doubleValue
    guard d.rounded() == d, abs(d) < 1e15 else { return nil }
    return Int(d)
  }

  /// A JSON `true` or `false`, which Foundation also hands back as an
  /// `NSNumber`.
  static func isBoolean(_ n: NSNumber) -> Bool {
    #if canImport(Darwin)
      CFGetTypeID(n) == CFBooleanGetTypeID()
    #else
      // swift-corelibs-foundation: a JSON boolean is an `NSNumber` of a
      // `Bool`, whose Objective-C type is `c`; JSON has no char numbers.
      String(cString: n.objCType) == "c"
    #endif
  }

  static func describe(_ w: GuestCUWaitResult, _ seq: UInt64?) -> String {
    let at = seq.map { " (damageSeq \($0))" } ?? ""
    switch w.outcome {
    case .settled: return "screen settled after \(w.elapsedMs) ms\(at)"
    case .unchanged: return "screen unchanged after \(w.elapsedMs) ms\(at)"
    case .timedOut:
      return
        "screen still changing after \(w.elapsedMs) ms\(at); take a screenshot, or wait_for_screen on a smaller region"
    }
  }

  /// The settle wait after an action. The action has already run, so
  /// nothing here fails the tool call: a refusal is reported in the text.
  private func settled(since: UInt64, idleMs: Int) -> String {
    guard let session else { return "settling skipped: no session" }
    var q = GuestCURequest(op: .wait, session: session)
    q.since = since
    q.until = .idle
    q.idleMs = idleMs
    q.timeoutMs = GuestCUProtocol.Wait.settleTimeoutMs
    guard let r = try? send(q) else { return "settling skipped: the host did not answer" }
    guard r.ok, let w = r.wait else {
      return "settling skipped: refused (\(r.refusal?.rawValue ?? "error"))"
    }
    return Self.describe(w, r.damageSeq)
  }

  private func hostSupportsWait() throws -> Bool {
    if let supportsWait { return supportsWait }
    let r = try checked(try send(GuestCURequest(op: .status)))
    supportsWait = r.damageSeq != nil
    return r.damageSeq != nil
  }

  private func waitForScreen(_ args: [String: Any]) throws -> [String: Any] {
    guard try hostSupportsWait() else {
      throw ToolError(message: "wait_for_screen is not supported by this host")
    }
    func optionalInteger(_ key: String) throws -> Int? {
      guard let value = args[key] else { return nil }
      guard let n = Self.integer(value) else {
        throw ToolError(message: "\(key) must be an integer")
      }
      return n
    }
    let since = try optionalInteger("since")
    if let since, since < 0 { throw ToolError(message: "since must not be negative") }
    let idle = try optionalInteger("idle_ms")
    let timeout = try optionalInteger("timeout_ms")
    var until: GuestCUWaitUntil?
    if let value = args["until"] {
      guard let s = value as? String, let u = GuestCUWaitUntil(rawValue: s) else {
        throw ToolError(message: "until must be change or idle")
      }
      until = u
    }
    var region: GuestCURegion?
    if let value = args["region"] {
      guard let o = value as? [String: Any], Set(o.keys) == GuestCURegion.fields,
        let x = Self.integer(o["x"]), let y = Self.integer(o["y"]),
        let w = Self.integer(o["width"]), let h = Self.integer(o["height"])
      else { throw ToolError(message: "region needs integer x, y, width and height only") }
      region = GuestCURegion(x: x, y: y, width: w, height: h)
    }
    let include = args["include_screenshot"] as? Bool ?? true
    let r = try withSession {
      var q = GuestCURequest(op: .wait, session: $0)
      q.since = since.map(UInt64.init)
      q.idleMs = idle
      q.timeoutMs = timeout
      q.until = until
      q.region = region
      return q
    }
    guard let w = r.wait else { throw ToolError(message: "no wait result") }
    var content: [[String: Any]] = [["type": "text", "text": Self.describe(w, r.damageSeq)]]
    if include, let session {
      // A separate frame request, against the frame rate.
      let f = try send(GuestCURequest(op: .frame, session: session))
      if f.ok {
        content = try Self.screenshot(f) + content
      } else if f.refusal == .rateLimited {
        content.append([
          "type": "text",
          "text": "no screenshot: the frame rate limit was reached; take one shortly",
        ])
      } else {
        content.append([
          "type": "text",
          "text":
            "no screenshot: refused (\(f.refusal?.rawValue ?? "error")): \(f.error ?? "no detail")",
        ])
      }
    }
    return ["content": content]
  }

  static func action(_ name: String, _ args: [String: Any]) throws -> GuestCUAction {
    func number(_ key: String) -> Double? { (args[key] as? NSNumber)?.doubleValue }
    func integer(_ key: String) -> Int? { (args[key] as? NSNumber)?.intValue }
    var a = GuestCUAction(kind: name)
    a.x = number("x")
    a.y = number("y")
    a.button = args["button"] as? String
    a.count = integer("count")
    a.dx = integer("dx")
    a.dy = integer("dy")
    a.keyCode = integer("keyCode")
    a.modifiers = args["modifiers"] as? [String]
    a.text = args["text"] as? String
    if let path = args["path"] as? [[String: Any]] {
      a.path = try path.map { p in
        guard let x = (p["x"] as? NSNumber)?.doubleValue, let y = (p["y"] as? NSNumber)?.doubleValue
        else { throw ToolError(message: "every path point needs x and y") }
        return GuestCUPoint(x: x, y: y)
      }
    }
    return a
  }

  /// Runs a request on the guest's session, opening one if needed and
  /// reopening it once if the host has forgotten it.
  private func withSession(_ make: (String) -> GuestCURequest) throws -> GuestCUResponse {
    for attempt in 0..<2 {
      let id = try openSession()
      let r = try send(make(id))
      if !r.ok, attempt == 0, r.refusal == .unknownSession || r.refusal == .sessionRefused {
        session = nil
        // An action refused part-way may have sent input: never twice.
        guard make(id).op != .act || r.beforeInput == true else {
          throw ToolError(
            message:
              "the session ended part-way through the action, so some of it may have been applied; take a screenshot before retrying"
          )
        }
        continue
      }
      return try checked(r)
    }
    throw ToolError(message: "no session")
  }

  private func openSession() throws -> String {
    if let session { return session }
    let r = try checked(try send(GuestCURequest(op: .session)))
    guard let id = r.session else { throw ToolError(message: "no session") }
    session = id
    return id
  }

  private func checked(_ r: GuestCUResponse) throws -> GuestCUResponse {
    guard !r.ok else { return r }
    if r.refusal == .heldByHost {
      let remaining = (try? send(GuestCURequest(op: .status)))?.holdRemainingSeconds
      throw ToolError(
        message:
          "The host has control of the display\(remaining.map { " for \($0) more seconds" } ?? ""); wait, then try again."
      )
    }
    throw ToolError(
      message: "refused (\(r.refusal?.rawValue ?? "error")): \(r.error ?? "no detail")")
  }
}
