import Foundation

// Computer-use contract (docs/design/macos-guest-computer-use.md): framebuffer
// pixels, origin top-left, range [0,width) × [0,height); one pointer, one
// keyboard. Everything here is pure so it is unit-testable.

package enum CUButton: String, Codable, Sendable { case left, right, middle }

package enum CUModifier: String, Codable, Sendable, CaseIterable {
  case shift, control, option, command

  /// macOS virtual key code of the left-hand key.
  package var keyCode: Int {
    switch self {
    case .shift: 56
    case .control: 59
    case .option: 58
    case .command: 55
    }
  }
  /// NSEvent device-independent flag.
  package var flag: UInt {
    switch self {
    case .shift: 1 << 17
    case .control: 1 << 18
    case .option: 1 << 19
    case .command: 1 << 20
    }
  }
  /// Device-dependent (left-hand) bit; the view ignores modifiers without it.
  package var deviceBit: UInt {
    switch self {
    case .shift: 0x2
    case .control: 0x1
    case .option: 0x20
    case .command: 0x8
    }
  }
}

package struct CUPoint: Codable, Equatable, Sendable {
  package var x: Double
  package var y: Double
  package init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

/// A validated action. Built only through ``CUActionRequest/validated(width:height:)``.
package enum CUAction: Equatable, Sendable {
  case move(CUPoint)
  case click(CUPoint, CUButton, count: Int)
  case down(CUPoint, CUButton)
  case up(CUPoint, CUButton)
  case drag([CUPoint], CUButton)
  case scroll(CUPoint, dx: Int, dy: Int)
  case key(keyCode: Int, modifiers: [CUModifier])
  case type(String)
}

/// The wire form of an action.
package struct CUActionRequest: Codable, Sendable {
  package var kind: String
  package var x: Double?
  package var y: Double?
  package var button: CUButton?
  package var count: Int?
  package var path: [CUPoint]?
  package var dx: Int?
  package var dy: Int?
  package var keyCode: Int?
  package var modifiers: [CUModifier]?
  package var text: String?

  package init(kind: String) { self.kind = kind }

  package static let maxPath = 1000
  package static let maxText = 4096
  package static let maxScroll = 10_000

  /// Refuses (never clamps) anything outside the contract.
  package func validated(width: Int, height: Int) throws -> CUAction {
    func point(_ p: CUPoint) throws -> CUPoint {
      guard p.x.isFinite, p.y.isFinite, p.x >= 0, p.y >= 0, p.x < Double(width),
        p.y < Double(height)
      else { throw SandboxError("coordinate (\(p.x), \(p.y)) outside [0,\(width))×[0,\(height))") }
      return p
    }
    func here() throws -> CUPoint {
      guard let x, let y else { throw SandboxError("\(kind) needs x and y") }
      return try point(CUPoint(x: x, y: y))
    }
    switch kind {
    case "move": return .move(try here())
    case "click":
      let n = count ?? 1
      guard (1...3).contains(n) else { throw SandboxError("count must be 1-3") }
      return .click(try here(), button ?? .left, count: n)
    case "down": return .down(try here(), button ?? .left)
    case "up": return .up(try here(), button ?? .left)
    case "drag":
      guard let path, (2...Self.maxPath).contains(path.count) else {
        throw SandboxError("drag path needs 2-\(Self.maxPath) points")
      }
      return .drag(try path.map(point), button ?? .left)
    case "scroll":
      let sx = dx ?? 0
      let sy = dy ?? 0
      guard abs(sx) <= Self.maxScroll, abs(sy) <= Self.maxScroll, sx != 0 || sy != 0 else {
        throw SandboxError("scroll needs a non-zero dx or dy within ±\(Self.maxScroll)")
      }
      return .scroll(try here(), dx: sx, dy: sy)
    case "key":
      guard let keyCode, (0...127).contains(keyCode) else {
        throw SandboxError("keyCode must be 0-127")
      }
      let mods = modifiers ?? []
      guard Set(mods).count == mods.count else { throw SandboxError("duplicate modifier") }
      guard !CUModifier.allCases.map(\.keyCode).contains(keyCode) else {
        throw SandboxError("use modifiers, not a modifier key code")
      }
      return .key(keyCode: keyCode, modifiers: mods)
    case "type":
      guard let text, !text.isEmpty, text.count <= Self.maxText else {
        throw SandboxError("type needs 1-\(Self.maxText) characters")
      }
      for c in text.unicodeScalars where USKeyboard.lookup(c) == nil {
        throw SandboxError(
          "type supports printable ASCII and \\n \\t only (got U+\(String(c.value, radix: 16)))")
      }
      return .type(text)
    default:
      throw SandboxError("unknown action \(kind.debugDescription)")
    }
  }
}

/// One synthesized keyboard event.
package struct CUKeyEvent: Equatable, Sendable {
  package enum Kind: String, Sendable { case down, up, flags }
  package var kind: Kind
  package var keyCode: Int
  package var characters: String
  /// Device-independent plus device-dependent bits.
  package var flags: UInt
}

package enum CUKeys {
  static func flags(_ mods: [CUModifier]) -> UInt {
    let dev = mods.reduce(UInt(0)) { $0 | $1.deviceBit }
    return mods.reduce(UInt(0)) { $0 | $1.flag } | dev | (dev != 0 ? 0x100 : 0)
  }

  /// Press modifiers in order, tap the key, release in reverse: every press
  /// has its release, so a complete sequence leaves nothing held.
  package static func chord(keyCode: Int, modifiers: [CUModifier], characters: String = "")
    -> [CUKeyEvent]
  {
    var out: [CUKeyEvent] = []
    var held: [CUModifier] = []
    for m in modifiers {
      held.append(m)
      out.append(.init(kind: .flags, keyCode: m.keyCode, characters: "", flags: flags(held)))
    }
    out.append(.init(kind: .down, keyCode: keyCode, characters: characters, flags: flags(held)))
    out.append(.init(kind: .up, keyCode: keyCode, characters: characters, flags: flags(held)))
    for m in modifiers.reversed() {
      held.removeLast()
      out.append(.init(kind: .flags, keyCode: m.keyCode, characters: "", flags: flags(held)))
    }
    return out
  }

  package static func events(forText text: String) -> [CUKeyEvent] {
    text.unicodeScalars.flatMap { c -> [CUKeyEvent] in
      guard let (code, shift) = USKeyboard.lookup(c) else { return [] }
      return chord(keyCode: code, modifiers: shift ? [.shift] : [], characters: String(c))
    }
  }

  /// The releases that undo whatever `events` left pressed if cut short
  /// after `sent` of them.
  package static func releases(after events: ArraySlice<CUKeyEvent>) -> [CUKeyEvent] {
    var keys: [Int: String] = [:]
    var mods: [CUModifier] = []
    for e in events {
      switch e.kind {
      case .down: keys[e.keyCode] = e.characters
      case .up: keys[e.keyCode] = nil
      case .flags:
        if let m = CUModifier.allCases.first(where: { $0.keyCode == e.keyCode }) {
          if e.flags & m.flag != 0 { mods.append(m) } else { mods.removeAll { $0 == m } }
        }
      }
    }
    var out: [CUKeyEvent] = keys.sorted { $0.key < $1.key }.map {
      .init(kind: .up, keyCode: $0.key, characters: $0.value, flags: flags(mods))
    }
    while let m = mods.popLast() {
      out.append(.init(kind: .flags, keyCode: m.keyCode, characters: "", flags: flags(mods)))
    }
    return out
  }
}

/// US ANSI layout: ASCII character → (virtual key code, needs shift).
package enum USKeyboard {
  static let plain: [Character: Int] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
    "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
    "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
    "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
    ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49, "`": 50, "\n": 36, "\t": 48,
  ]
  static let shifted: [Character: Character] = [
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9",
    ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",",
    ">": ".", "?": "/", "~": "`",
  ]

  package static func lookup(_ scalar: Unicode.Scalar) -> (Int, Bool)? {
    let c = Character(scalar)
    if let code = plain[c] { return (code, false) }
    if c.isASCII, c.isUppercase, let code = plain[Character(c.lowercased())] { return (code, true) }
    if let base = shifted[c], let code = plain[base] { return (code, true) }
    return nil
  }
}

/// What a session is bound to (Gate H). Any difference refuses the session.
package struct CUBinding: Codable, Equatable, Sendable {
  package var bootId: String
  package var vmInstance: String
  package var guestBoot: String
  package var helperGeneration: Int
  package var width: Int
  package var height: Int

  package init(
    bootId: String, vmInstance: String, guestBoot: String, helperGeneration: Int, width: Int,
    height: Int
  ) {
    self.bootId = bootId
    self.vmInstance = vmInstance
    self.guestBoot = guestBoot
    self.helperGeneration = helperGeneration
    self.width = width
    self.height = height
  }

  /// Why `current` no longer matches this binding, or nil.
  package func mismatch(_ current: CUBinding?) -> String? {
    guard let current else { return "guest helper not connected" }
    if bootId != current.bootId { return "owner restarted" }
    if vmInstance != current.vmInstance { return "vm instance changed" }
    if guestBoot != current.guestBoot || helperGeneration != current.helperGeneration {
      return "guest boot changed"
    }
    if width != current.width || height != current.height { return "geometry changed" }
    return nil
  }
}

/// Sessions and recent frames for one owner (Gate H). Pure, so the refusal
/// rules are unit-testable; `MacScreen` adds the view-specific checks.
package struct CUSessions: Sendable {
  private var sessions: [String: CUBinding] = [:]
  private var frames: [String: CUBinding] = [:]
  private var frameOrder: [String] = []
  private var seq = 0
  package static let keptFrames = 64

  package init() {}

  package mutating func open(current: CUBinding?) throws -> (String, CUBinding) {
    guard let current else { throw SandboxError("guest helper not connected") }
    let id = UUID().uuidString.lowercased()
    sessions[id] = current
    return (id, current)
  }

  /// The session's binding if it still matches `current`. A session that no
  /// longer matches is forgotten, so it is refused from then on.
  package mutating func check(_ id: String?, current: CUBinding?) throws -> CUBinding {
    guard let id, let bound = sessions[id] else { throw SandboxError("unknown session") }
    if let why = bound.mismatch(current) {
      sessions[id] = nil
      throw SandboxError("session refused: \(why)")
    }
    return bound
  }

  /// Registers a frame captured under `binding`; returns its id and sequence.
  package mutating func recordFrame(_ binding: CUBinding) -> (id: String, seq: Int) {
    seq += 1
    let id = "\(binding.bootId.prefix(8))-\(seq)"
    frames[id] = binding
    frameOrder.append(id)
    if frameOrder.count > Self.keptFrames { frames[frameOrder.removeFirst()] = nil }
    return (id, seq)
  }

  /// An action based on `frame` must come from the session's own binding.
  package func requireFrame(_ frame: String, from binding: CUBinding) throws {
    guard let captured = frames[frame] else { throw SandboxError("unknown frame") }
    guard captured == binding else { throw SandboxError("frame from another binding") }
  }
}
