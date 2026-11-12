import CryptoKit
import Foundation
import IsoMacProtocol
import Security

// Live view and browser takeover (docs/design/computer-use-live-view.md):
// everything a browser can send is parsed here into closed types, and the
// takeover and stuck-input rules are pure state, so all of it is
// unit-testable without a VM or a socket.

package enum LiveView {
  /// Viewers at once; one of them may control.
  package static let maxViewers = 2
  /// Largest WebSocket message a viewer may send.
  package static let maxMessage = 4096
  /// Deepest a viewer message nests: every one is a flat object. A deeper
  /// message is refused before any parser reads it.
  package static let maxNesting = 1
  /// Largest ping a viewer may send (RFC 6455 §5.5: control frames carry at
  /// most 125 bytes).
  package static let maxControlFrame = 125
  /// Characters of pasted text in one message. Every character may take two
  /// bytes of JSON, so the largest paste still fits `maxMessage`.
  package static let maxPaste = 2000
  /// Largest HTTP request head the owner reads.
  package static let maxRequestHead = 8192
  /// A viewer must authenticate this soon after the upgrade.
  package static let tokenDeadline: TimeInterval = 5
  /// The stream stops after this long with no viewer.
  package static let idleStop: TimeInterval = 60
  /// A viewer whose socket accepts nothing for this long is disconnected.
  package static let stalledViewer: TimeInterval = 10
  /// Frames per second while the screen changes or the viewer gives input.
  /// Provisional: §3's capture spike sets the real cap.
  package static let frameRateCap = 30
  /// Frames per second on a static screen.
  package static let staticFrameRate = 2
  /// Bytes queued for one viewer before its frames are dropped to the next
  /// keyframe.
  package static let queueLimit = 8 * 1024 * 1024
  /// Bytes per write of a viewer's queue: a video frame is tens to hundreds
  /// of kilobytes, far more than the helper lines `BoundedWrite` defaults to.
  package static let writeChunk = 64 * 1024
  /// Viewer messages a second (input, control and pings), as for guest actions.
  /// Releases (key up, button up, release of control) are counted apart, at
  /// the same rate: see ``LiveViewLimits``.
  package static let messageRate = 100
  /// TCP connections served at once, most of them not yet authenticated:
  /// two viewers, their page loads, and room for a browser's parallel
  /// requests. Past it a connection is closed unread.
  package static let maxConnections = 16

  /// `value` as 8 big-endian bytes.
  static func bigEndian(_ value: UInt64) -> [UInt8] {
    withUnsafeBytes(of: value.bigEndian) { Array($0) }
  }
}

/// One viewer's message budget. Everything is charged to `messages` except
/// what lets go of input, which has its own equal budget: a release is
/// never dropped because moves and scrolls used the budget up, or the guest
/// would keep a key or button down. A viewer cannot release more than it
/// pressed, so honest releases always fit; a flood of them is still bounded.
package struct LiveViewLimits: Sendable {
  private var messages: TokenBucket
  private var releases: TokenBucket

  package init(now: Date) {
    messages = TokenBucket(rate: LiveView.messageRate, now: now)
    releases = TokenBucket(rate: LiveView.messageRate, now: now)
  }

  static func isRelease(_ message: LiveViewMessage) -> Bool {
    switch message {
    case .release: true
    case .input(let input): input.isRelease
    default: false
    }
  }

  /// Whether to answer a ping: charged to the message budget, so pongs are
  /// bounded like every other reply.
  package mutating func admitPing(at now: Date) -> Bool { messages.take(1, at: now) }

  /// Whether to handle `parsed`; a refused message is dropped unanswered.
  package mutating func admit(
    _ parsed: Result<LiveViewMessage, LiveViewMessage.ParseError>, at now: Date
  ) -> Bool {
    if case .success(let message) = parsed, Self.isRelease(message) {
      return releases.take(1, at: now)
    }
    return messages.take(1, at: now)
  }
}

/// What becomes of one encoded frame offered to one viewer's queue (§4): a
/// viewer that cannot keep up loses frames up to the next keyframe that
/// fits, never the process's memory.
package enum LiveViewQueue {
  package enum Offer: Equatable, Sendable { case queue, drop }

  package static func offer(_ bytes: Int, keyframe: Bool, queued: Int, dropping: Bool) -> Offer {
    if dropping && !keyframe { return .drop }
    return queued + bytes > LiveView.queueLimit ? .drop : .queue
  }
}

// MARK: token

/// 256 random bits per stream start. Never logged: its description is
/// redacted, and it leaves the owner only in the control-socket reply.
package struct LiveViewToken: Sendable, CustomStringConvertible {
  package let value: String

  package init(value: String) { self.value = value }

  package static func random() throws -> LiveViewToken {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw SandboxError("no randomness for a stream token")
    }
    return LiveViewToken(value: HelperProtocol.hex(bytes))
  }

  /// Constant time for a candidate of the token's (public) length.
  package func matches(_ candidate: String) -> Bool {
    HelperProtocol.macMatches(value, candidate)
  }

  package var description: String { "<stream token>" }
}

// MARK: HTTP

package struct LiveViewHTTPRequest: Equatable, Sendable {
  package var method: String
  package var path: String
  /// Lowercased names. A repeated header is refused at parse.
  package var headers: [String: String]

  /// One request head (through the blank line), or nil.
  package static func parse(_ head: [UInt8]) -> LiveViewHTTPRequest? {
    guard head.count <= LiveView.maxRequestHead,
      let text = String(bytes: head, encoding: .ascii)
    else { return nil }
    var lines = text.components(separatedBy: "\r\n")
    guard lines.count >= 2 else { return nil }
    let start = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
    guard start.count == 3, start[2] == "HTTP/1.1" else { return nil }
    var headers: [String: String] = [:]
    for line in lines where !line.isEmpty {
      guard let colon = line.firstIndex(of: ":") else { return nil }
      let name = line[..<colon].lowercased()
      guard !name.isEmpty, headers[name] == nil else { return nil }
      headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    return LiveViewHTTPRequest(method: String(start[0]), path: String(start[1]), headers: headers)
  }
}

/// Where a request may go, decided before any token is read.
package enum LiveViewRoute: Equatable, Sendable {
  /// The viewer page, its script or its style: iso's own, embedded.
  case asset(contentType: String, body: String)
  case upgrade(acceptKey: String)
  case refused(status: Int, reason: Refusal)

  package enum Refusal: String, Sendable {
    /// `Host` is not exactly the listener (DNS rebinding).
    case host
    /// `Origin` is not exactly the listener (cross-site WebSocket hijacking).
    case origin
    case notFound
    case method
    case upgrade
  }

  package static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  package static func accept(_ key: String) -> String {
    Data(Insecure.SHA1.hash(data: Data((key + guid).utf8))).base64EncodedString()
  }

  /// The only resources are the page, its script and style, and the socket
  /// at `/ws`; all need the exact loopback `Host`, the socket also the exact
  /// `Origin`.
  package static func decide(_ r: LiveViewHTTPRequest, port: UInt16) -> LiveViewRoute {
    let origin = "127.0.0.1:\(port)"
    guard r.headers["host"] == origin else { return .refused(status: 421, reason: .host) }
    guard r.method == "GET" else { return .refused(status: 405, reason: .method) }
    switch r.path {
    case "/": return .asset(contentType: "text/html; charset=utf-8", body: LiveViewPage.html)
    case "/viewer.js":
      return .asset(contentType: "text/javascript; charset=utf-8", body: LiveViewPage.script)
    case "/viewer.css":
      return .asset(contentType: "text/css; charset=utf-8", body: LiveViewPage.style)
    case "/ws":
      guard r.headers["origin"] == "http://\(origin)" else {
        return .refused(status: 403, reason: .origin)
      }
      guard r.headers["upgrade"]?.lowercased() == "websocket",
        r.headers["connection"]?.lowercased().split(separator: ",").contains(where: {
          $0.trimmingCharacters(in: .whitespaces) == "upgrade"
        }) == true,
        r.headers["sec-websocket-version"] == "13",
        let key = r.headers["sec-websocket-key"], Data(base64Encoded: key)?.count == 16
      else { return .refused(status: 400, reason: .upgrade) }
      return .upgrade(acceptKey: accept(key))
    default:
      return .refused(status: 404, reason: .notFound)
    }
  }
}

// MARK: WebSocket frames

package enum WSFrame: Equatable, Sendable {
  case text(String)
  case binary([UInt8])
  case ping([UInt8])
  case pong
  case close

  package enum DecodeError: Error, Equatable {
    /// Client frames must be masked (RFC 6455 §5.1).
    case unmasked
    case tooLarge
    /// Fragmented messages are not used by the viewer page.
    case fragmented
    /// A close, ping or pong over 125 bytes (RFC 6455 §5.5).
    case controlTooLarge
    case reserved
    case badOpcode
    case notUTF8
  }

  /// One complete frame from the front of `buffer`, removed from it; nil
  /// while more bytes are needed.
  package static func decode(_ buffer: inout [UInt8]) throws(DecodeError) -> WSFrame? {
    guard buffer.count >= 2 else { return nil }
    let b0 = buffer[0]
    let b1 = buffer[1]
    guard b0 & 0x70 == 0 else { throw .reserved }
    guard b0 & 0x80 != 0 else { throw .fragmented }
    guard b1 & 0x80 != 0 else { throw .unmasked }
    var length = Int(b1 & 0x7F)
    var offset = 2
    if length == 126 {
      guard buffer.count >= 4 else { return nil }
      length = Int(buffer[2]) << 8 | Int(buffer[3])
      offset = 4
    } else if length == 127 {
      // Never needed for a 4 KiB message.
      throw .tooLarge
    }
    guard length <= LiveView.maxMessage else { throw .tooLarge }
    guard b0 & 0x08 == 0 || length <= LiveView.maxControlFrame else { throw .controlTooLarge }
    guard buffer.count >= offset + 4 + length else { return nil }
    let mask = Array(buffer[offset..<offset + 4])
    var payload = Array(buffer[(offset + 4)..<(offset + 4 + length)])
    for i in payload.indices { payload[i] ^= mask[i % 4] }
    buffer.removeFirst(offset + 4 + length)
    switch b0 & 0x0F {
    case 0x0: throw .fragmented
    case 0x1:
      guard let s = String(validating: payload, as: UTF8.self) else { throw .notUTF8 }
      return .text(s)
    case 0x2: return .binary(payload)
    case 0x8: return .close
    case 0x9: return .ping(payload)
    case 0xA: return .pong
    default: throw .badOpcode
    }
  }

  /// A server frame (never masked).
  package static func encode(opcode: UInt8, _ payload: [UInt8]) -> [UInt8] {
    var out: [UInt8] = [0x80 | opcode]
    switch payload.count {
    case 0..<126: out.append(UInt8(payload.count))
    case 126...0xFFFF:
      out += [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
    default:
      out.append(127)
      out += LiveView.bigEndian(UInt64(payload.count))
    }
    return out + payload
  }
}

// MARK: viewer messages

/// Raw viewer input: the second closed input set into the screen (§7).
package enum LiveViewInput: Equatable, Sendable {
  case move(CUPoint)
  case button(CUPoint, CUButton, down: Bool)
  case scroll(CUPoint, dx: Int, dy: Int)
  /// A Mac virtual key code from the fixed table.
  case key(keyCode: Int, down: Bool)

  /// Whether this lets go of a key or button.
  package var isRelease: Bool {
    switch self {
    case .button(_, _, down: false), .key(_, down: false): true
    default: false
    }
  }
}

package enum LiveViewMessage: Equatable, Sendable {
  case auth(String)
  case input(LiveViewInput)
  /// Pasted or typed text, under the `type` action's rules.
  case text(String)
  case take
  case release

  package enum ParseError: Error, Equatable {
    case tooLong, notJSON, malformed
    /// Nested past ``LiveView/maxNesting``; never parsed.
    case tooDeep
    case unknownType
    case unknownField
    /// A `KeyboardEvent.code` outside the table: dropped, not an error.
    case unknownKey
    case outOfRange
  }

  private static let fields: [String: Set<String>] = [
    "auth": ["type", "token"],
    "pointer": ["type", "kind", "x", "y", "button"],
    "scroll": ["type", "x", "y", "dx", "dy"],
    "key": ["type", "kind", "code"],
    "text": ["type", "text"],
    "control": ["type", "action"],
  ]

  package static func parse(_ text: String, width: Int, height: Int)
    -> Result<LiveViewMessage, ParseError>
  {
    guard text.utf8.count <= LiveView.maxMessage else { return .failure(.tooLong) }
    guard !JSONNesting.exceeds(text.utf8, limit: LiveView.maxNesting) else {
      return .failure(.tooDeep)
    }
    guard let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    else { return .failure(.notJSON) }
    guard let type = o["type"] as? String, let allowed = fields[type] else {
      return .failure(.unknownType)
    }
    guard Set(o.keys).isSubset(of: allowed) else { return .failure(.unknownField) }
    func number(_ k: String) -> Double? {
      guard let n = o[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
      return n.doubleValue
    }
    func integer(_ k: String) -> Int? {
      guard let d = number(k), d.rounded() == d, abs(d) <= 1e9 else { return nil }
      return Int(d)
    }
    func point() -> CUPoint? {
      guard let x = number("x"), let y = number("y"), x.isFinite, y.isFinite, x >= 0, y >= 0,
        x < Double(width), y < Double(height)
      else { return nil }
      return CUPoint(x: x, y: y)
    }
    switch type {
    case "auth":
      guard let t = o["token"] as? String else { return .failure(.malformed) }
      return .success(.auth(t))
    case "pointer":
      guard let kind = o["kind"] as? String else { return .failure(.malformed) }
      guard let p = point() else { return .failure(.outOfRange) }
      if kind == "move" {
        guard o["button"] == nil else { return .failure(.unknownField) }
        return .success(.input(.move(p)))
      }
      guard kind == "down" || kind == "up" else { return .failure(.malformed) }
      guard let b = (o["button"] as? String).flatMap(CUButton.init(rawValue:)) else {
        return .failure(.malformed)
      }
      return .success(.input(.button(p, b, down: kind == "down")))
    case "scroll":
      guard let p = point() else { return .failure(.outOfRange) }
      guard let dx = integer("dx"), let dy = integer("dy") else { return .failure(.malformed) }
      guard abs(dx) <= CUActionRequest.maxScroll, abs(dy) <= CUActionRequest.maxScroll,
        dx != 0 || dy != 0
      else { return .failure(.outOfRange) }
      return .success(.input(.scroll(p, dx: dx, dy: dy)))
    case "key":
      guard let kind = o["kind"] as? String, kind == "down" || kind == "up",
        let code = o["code"] as? String
      else { return .failure(.malformed) }
      guard let keyCode = LiveViewKeys.macKeyCode(code) else { return .failure(.unknownKey) }
      return .success(.input(.key(keyCode: keyCode, down: kind == "down")))
    case "text":
      guard let s = o["text"] as? String else { return .failure(.malformed) }
      guard s.count <= LiveView.maxPaste else { return .failure(.outOfRange) }
      var r = CUActionRequest(kind: "type")
      r.text = s
      guard (try? r.validated(width: width, height: height)) != nil else {
        return .failure(.outOfRange)
      }
      return .success(.text(s))
    case "control":
      switch o["action"] as? String {
      case "take": return .success(.take)
      case "release": return .success(.release)
      default: return .failure(.malformed)
      }
    default:
      return .failure(.unknownType)
    }
  }
}

/// `KeyboardEvent.code` (physical keys, US layout) to Mac virtual key codes.
/// Anything not here is dropped.
package enum LiveViewKeys {
  static let table: [String: Int] = {
    var t: [String: Int] = [
      "KeyA": 0, "KeyS": 1, "KeyD": 2, "KeyF": 3, "KeyH": 4, "KeyG": 5, "KeyZ": 6, "KeyX": 7,
      "KeyC": 8, "KeyV": 9, "IntlBackslash": 10, "KeyB": 11, "KeyQ": 12, "KeyW": 13, "KeyE": 14,
      "KeyR": 15, "KeyY": 16, "KeyT": 17, "Digit1": 18, "Digit2": 19, "Digit3": 20,
      "Digit4": 21, "Digit6": 22, "Digit5": 23, "Equal": 24, "Digit9": 25, "Digit7": 26,
      "Minus": 27, "Digit8": 28, "Digit0": 29, "BracketRight": 30, "KeyO": 31, "KeyU": 32,
      "BracketLeft": 33, "KeyI": 34, "KeyP": 35, "Enter": 36, "KeyL": 37, "KeyJ": 38,
      "Quote": 39, "KeyK": 40, "Semicolon": 41, "Backslash": 42, "Comma": 43, "Slash": 44,
      "KeyN": 45, "KeyM": 46, "Period": 47, "Tab": 48, "Space": 49, "Backquote": 50,
      "Backspace": 51, "Escape": 53, "CapsLock": 57,
      "F5": 96, "F6": 97, "F7": 98, "F3": 99, "F8": 100, "F9": 101, "F11": 103, "F10": 109,
      "F12": 111, "Home": 115, "PageUp": 116, "Delete": 117, "F4": 118, "End": 119, "F2": 120,
      "PageDown": 121, "F1": 122, "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125,
      "ArrowUp": 126,
    ]
    // Either hand's modifier is the left-hand key the view understands.
    for (code, m) in modifierCodes { t[code] = m.keyCode }
    return t
  }()

  static let modifierCodes: [String: CUModifier] = [
    "ShiftLeft": .shift, "ShiftRight": .shift, "ControlLeft": .control,
    "ControlRight": .control, "AltLeft": .option, "AltRight": .option, "MetaLeft": .command,
    "MetaRight": .command,
  ]

  package static func macKeyCode(_ code: String) -> Int? { table[code] }

  package static func modifier(keyCode: Int) -> CUModifier? {
    CUModifier.allCases.first { $0.keyCode == keyCode }
  }
}

// MARK: held input

/// The buttons and keys the controlling viewer holds down, so they are
/// released on release, disconnect, hold expiry and stream stop (§7).
package struct LiveViewHeld: Equatable, Sendable {
  package private(set) var buttons: Set<CUButton> = []
  package private(set) var keys: Set<Int> = []
  package private(set) var modifiers: [CUModifier] = []
  /// Where the pointer last was, for releasing buttons in place.
  package private(set) var pointer = CUPoint(x: 0, y: 0)

  package init() {}

  package var flags: UInt { CUKeys.flags(modifiers) }
  package var isEmpty: Bool { buttons.isEmpty && keys.isEmpty && modifiers.isEmpty }

  /// Records `input`; returns false for an input that would change nothing
  /// (a second press of a held key, a release of an unheld one).
  package mutating func apply(_ input: LiveViewInput) -> Bool {
    switch input {
    case .move(let p), .scroll(let p, _, _):
      pointer = p
      return true
    case .button(let p, let b, let down):
      pointer = p
      return down ? buttons.insert(b).inserted : buttons.remove(b) != nil
    case .key(let code, let down):
      if let m = LiveViewKeys.modifier(keyCode: code) {
        if down {
          guard !modifiers.contains(m) else { return false }
          modifiers.append(m)
        } else {
          guard modifiers.contains(m) else { return false }
          modifiers.removeAll { $0 == m }
        }
        return true
      }
      return down ? keys.insert(code).inserted : keys.remove(code) != nil
    }
  }

  /// The inputs that let go of everything held, keys first, then
  /// modifiers, then buttons; and empties the state.
  package mutating func releaseAll() -> [LiveViewInput] {
    var out: [LiveViewInput] = keys.sorted().map { .key(keyCode: $0, down: false) }
    out += modifiers.reversed().map { .key(keyCode: $0.keyCode, down: false) }
    out += buttons.sorted { $0.rawValue < $1.rawValue }.map { .button(pointer, $0, down: false) }
    buttons = []
    keys = []
    modifiers = []
    return out
  }
}

// MARK: takeover

/// Which viewer controls, and until when (§6). Taking control takes the
/// host hold; each accepted input extends it; a viewer whose 60 s ran out
/// is view-only again and its held input is released.
package struct LiveViewControl: Equatable, Sendable {
  /// The controlling viewer and when its control lapses: both or neither.
  private var holder: (viewer: Int, until: Date)?

  package init() {}

  package var controller: Int? { holder?.viewer }

  package static func == (a: LiveViewControl, b: LiveViewControl) -> Bool {
    a.holder?.viewer == b.holder?.viewer && a.holder?.until == b.holder?.until
  }

  package enum Take: Equatable, Sendable { case taken, otherViewerControls }

  package mutating func take(_ viewer: Int, at now: Date) -> Take {
    if let holder, holder.viewer != viewer, holder.until > now {
      return .otherViewerControls
    }
    holder = (viewer, now.addingTimeInterval(CUControl.implicitHold))
    return .taken
  }

  package enum Admit: Equatable, Sendable {
    /// Send it; the hold is extended to 60 s from now.
    case accepted
    /// Dropped: this viewer does not control.
    case viewOnly
    /// Dropped: this viewer's control lapsed; release what it holds.
    case expired
  }

  package mutating func admit(_ viewer: Int, at now: Date) -> Admit {
    guard let holder, holder.viewer == viewer else { return .viewOnly }
    guard holder.until > now else {
      self.holder = nil
      return .expired
    }
    self.holder = (viewer, now.addingTimeInterval(CUControl.implicitHold))
    return .accepted
  }

  /// The viewer whose control ran out by `now`, now view-only; nil if none.
  package mutating func lapse(at now: Date) -> Int? {
    guard let holder, holder.until <= now else { return nil }
    self.holder = nil
    return holder.viewer
  }

  /// A viewer left: what to send to let go of its held input. Nothing
  /// unless it controlled; its hold is left to expire.
  package mutating func disconnect(_ viewer: Int, held: inout LiveViewHeld) -> [LiveViewInput] {
    guard release(viewer) else { return [] }
    return held.releaseAll()
  }

  /// True when `viewer` controlled (so the caller releases its input).
  package mutating func release(_ viewer: Int) -> Bool {
    guard holder?.viewer == viewer else { return false }
    holder = nil
    return true
  }
}
