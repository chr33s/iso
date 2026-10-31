import Foundation

/// Why the owner refused a computer-use request, carried beside the message
/// on the control socket and on the guest computer-use channel.
package enum CURefusal: String, Codable, Sendable {
  case helperGone = "helper_gone"
  case unknownSession = "unknown_session"
  case sessionRefused = "session_refused"
  case unknownFrame = "unknown_frame"
  case foreignFrame = "foreign_frame"
  case noWindow = "no_window"
  case blankFrame = "blank_frame"
  case busy
  case invalidAction = "invalid_action"
  /// The host holds computer use; guest requests wait for it to end.
  case heldByHost = "held_by_host"
  case rateLimited = "rate_limited"

  /// The session or frame binding is void: no decision made on it stands.
  package var voidsBinding: Bool {
    switch self {
    case .helperGone, .unknownSession, .sessionRefused, .unknownFrame, .foreignFrame, .noWindow:
      true
    case .blankFrame, .busy, .invalidAction, .heldByHost, .rateLimited: false
    }
  }
}

/// Guest-driven computer use (docs/design/guest-driven-computer-use.md): a
/// guest process asks its VM's owner for frames and input on vsock 7802.
/// One JSON object per line, one request then one response.
package enum GuestCUProtocol {
  package static let port: UInt32 = 7802
  /// Largest request line the host reads.
  package static let maxRequest = HelperProtocol.maxLine
  /// Largest response line the guest reads: a base64 1920×1200 PNG and its
  /// metadata.
  package static let maxResponse = 16 * 1024 * 1024
  /// Connections the host serves at once.
  package static let maxConnections = 2
  /// A response write that takes longer drops the connection.
  package static let writeDeadline: TimeInterval = 10
  /// Frames per second a guest may take: the configured default and range.
  package static let defaultFrameRate = 4
  package static let frameRates = 1...10
  /// Actions (and `status` requests) per second; `type` costs one per 64
  /// characters.
  package static let actionRate = 20
  /// Requests per second of any kind, refused ones included.
  package static let requestRate = 100
  package static let typeCharactersPerAction = 64
}

/// Who drives the display now.
package enum GuestCUController: String, Codable, Sendable { case idle, guest, host }

package struct GuestCUPoint: Codable, Equatable, Sendable {
  package var x: Double
  package var y: Double
  package init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

/// The guest's form of an action. Field names match the runtime's
/// `CUActionRequest`, which the host decodes and validates.
package struct GuestCUAction: Codable, Equatable, Sendable {
  package var kind: String
  package var x: Double?
  package var y: Double?
  package var button: String?
  package var count: Int?
  package var path: [GuestCUPoint]?
  package var dx: Int?
  package var dy: Int?
  package var keyCode: Int?
  package var modifiers: [String]?
  package var text: String?

  package init(kind: String) { self.kind = kind }

  static let fields: Set<String> = [
    "kind", "x", "y", "button", "count", "path", "dx", "dy", "keyCode", "modifiers", "text",
  ]
}

package struct GuestCURequest: Codable, Equatable, Sendable {
  package enum Op: String, Codable, Sendable { case session, frame, act, status }
  package var op: Op
  package var session: String?
  package var action: GuestCUAction?
  package var basedOnFrame: String?

  package init(
    op: Op, session: String? = nil, action: GuestCUAction? = nil, basedOnFrame: String? = nil
  ) {
    self.op = op
    self.session = session
    self.action = action
    self.basedOnFrame = basedOnFrame
  }

  static let fields: Set<String> = ["op", "session", "action", "basedOnFrame"]

  /// Whether this request may be sent again on a new connection after the
  /// first got no reply. One the host received in full (`written`) may
  /// have run, so an action never goes twice; a failed write delivered at
  /// most part of a line, which the host cannot act on.
  package func mayResend(written: Bool) -> Bool { op != .act || !written }

  package enum ParseError: Error, Equatable {
    case tooLong, notJSON
    case unknownField(String)
    case malformed
    case missing(String)

    /// The kind only: an unknown field's name is guest-chosen text, never
    /// logged.
    package var kind: String {
      switch self {
      case .tooLong: "too long"
      case .notJSON: "not JSON"
      case .unknownField: "unknown field"
      case .malformed: "malformed"
      case .missing(let field): "missing \(field)"
      }
    }
  }

  /// A guest-authored line, refused unless it is exactly one known request.
  package static func parse(_ line: [UInt8]) -> Result<GuestCURequest, ParseError> {
    guard line.count <= GuestCUProtocol.maxRequest else { return .failure(.tooLong) }
    guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
    else { return .failure(.notJSON) }
    if let extra = Set(object.keys).subtracting(fields).sorted().first {
      return .failure(.unknownField(extra))
    }
    if let action = object["action"] {
      guard let a = action as? [String: Any] else { return .failure(.malformed) }
      if let extra = Set(a.keys).subtracting(GuestCUAction.fields).sorted().first {
        return .failure(.unknownField("action.\(extra)"))
      }
    }
    guard let r = try? JSONDecoder().decode(GuestCURequest.self, from: Data(line)) else {
      return .failure(.malformed)
    }
    switch r.op {
    case .session, .status: break
    case .frame:
      guard r.session != nil else { return .failure(.missing("session")) }
    case .act:
      guard r.session != nil else { return .failure(.missing("session")) }
      guard r.action != nil else { return .failure(.missing("action")) }
      // Guest actions always name the frame they were decided on.
      guard r.basedOnFrame != nil else { return .failure(.missing("basedOnFrame")) }
    }
    return .success(r)
  }
}

package struct GuestCUFrame: Codable, Equatable, Sendable {
  package var frameId: String
  package var width: Int
  package var height: Int
  package var png: Data

  package init(frameId: String, width: Int, height: Int, png: Data) {
    self.frameId = frameId
    self.width = width
    self.height = height
    self.png = png
  }
}

package struct GuestCUResponse: Codable, Equatable, Sendable {
  package var ok: Bool
  package var error: String?
  package var refusal: CURefusal?
  package var beforeInput: Bool?
  package var session: String?
  package var frame: GuestCUFrame?
  package var submitted: Int?
  package var controller: GuestCUController?
  package var holdRemainingSeconds: Int?

  package init(ok: Bool) { self.ok = ok }

  package static func refused(_ message: String, _ refusal: CURefusal?, beforeInput: Bool? = nil)
    -> GuestCUResponse
  {
    var r = GuestCUResponse(ok: false)
    r.error = message
    r.refusal = refusal
    r.beforeInput = beforeInput
    return r
  }

  package func encodedLine() -> Data {
    var d = (try? JSONEncoder().encode(self)) ?? Data(#"{"ok":false}"#.utf8)
    d.append(0x0A)
    return d
  }
}
