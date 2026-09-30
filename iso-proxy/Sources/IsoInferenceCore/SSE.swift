/// One server-sent event: the `event` field (if any) and the joined `data`.
public struct SSEEvent: Sendable, Equatable {
  public let name: String?
  public let data: [UInt8]

  public init(name: String?, data: [UInt8]) {
    self.name = name
    self.data = data
  }
}

/// An incremental, bounded `text/event-stream` parser. `id`, `retry` and
/// comment lines are ignored; a line or event longer than `maxEventBytes`
/// fails the stream instead of growing the buffer.
public struct SSEParser: Sendable {
  public enum Failure: Error, Sendable, Equatable { case eventTooLarge, invalidUTF8 }

  let maxEventBytes: Int
  var line: [UInt8] = []
  var name: String?
  var data: [UInt8] = []
  var hasData = false
  var eventBytes = 0
  var lastWasCR = false

  public init(maxEventBytes: Int) { self.maxEventBytes = maxEventBytes }

  public mutating func feed(_ bytes: some Sequence<UInt8>) throws(Failure) -> [SSEEvent] {
    var events: [SSEEvent] = []
    for byte in bytes {
      if lastWasCR {
        lastWasCR = false
        if byte == 0x0A { continue }
      }
      switch byte {
      case 0x0A, 0x0D:
        lastWasCR = byte == 0x0D
        if let event = try endLine() { events.append(event) }
      default:
        line.append(byte)
        eventBytes += 1
        guard eventBytes <= maxEventBytes else { throw .eventTooLarge }
      }
    }
    return events
  }

  mutating func endLine() throws(Failure) -> SSEEvent? {
    defer { line.removeAll(keepingCapacity: true) }
    if line.isEmpty {
      defer {
        name = nil
        data.removeAll()
        hasData = false
        eventBytes = 0
      }
      guard hasData else { return nil }
      return SSEEvent(name: name, data: data)
    }
    if line.first == UInt8(ascii: ":") { return nil }
    let colon = line.firstIndex(of: UInt8(ascii: ":"))
    let field = colon.map { Array(line[..<$0]) } ?? line
    var value = colon.map { Array(line[($0 + 1)...]) } ?? []
    if value.first == 0x20 { value.removeFirst() }
    switch field {
    case Array("data".utf8):
      if hasData { data.append(0x0A) }
      data.append(contentsOf: value)
      hasData = true
    case Array("event".utf8):
      guard let text = String(validating: value, as: UTF8.self) else { throw .invalidUTF8 }
      name = text
    default: break
    }
    return nil
  }
}

extension SSEEvent {
  /// Wire form re-emitted to a streaming client.
  public static func encode(name: String?, data: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    if let name {
      out.append(contentsOf: Array("event: ".utf8))
      out.append(contentsOf: Array(name.utf8))
      out.append(0x0A)
    }
    out.append(contentsOf: Array("data: ".utf8))
    out.append(contentsOf: data)
    out.append(contentsOf: [0x0A, 0x0A])
    return out
  }

  public static let keepAlive: [UInt8] = Array(": keep-alive\n\n".utf8)
}
