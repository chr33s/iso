import Darwin
import IsoEgressCore

/// The CONNECT head terminator scan (`HeadTerminator`), as `ConnectGate.readHead`
/// drives it across reads, and `readHead` itself over a socket pair. Bytes
/// after the terminator belong to the tunnel and must stay unread.
public enum EgressHeadHarness {
  public static func run(_ bytes: [UInt8]) {
    guard let schedule = bytes.first else { return }
    let data = Array(bytes.dropFirst())
    let expected = firstTerminatorEnd(Array(data.prefix(EgressBudgets.maxHeadBytes)))
    // The read loop with chunk sizes chosen by the input.
    var head: [UInt8] = []
    var cursor = 0
    var size = Int(schedule) + 1
    while head.count < EgressBudgets.maxHeadBytes, cursor < data.count {
      let length = min(size, 4096, EgressBudgets.maxHeadBytes - head.count, data.count - cursor)
      let take = HeadTerminator.take(after: head, next: data[cursor..<(cursor + length)])
      require(take >= 1 && take <= length, "take within the read")
      head += data[cursor..<(cursor + take)]
      cursor += take
      if head.suffix(4).elementsEqual(terminator) { break }
      size = size * 7 % 4099 + 1
    }
    if let expected {
      require(head.count == expected, "head ends at the first terminator")
    } else {
      require(firstTerminatorEnd(head) == nil, "no terminator inside an unfinished head")
    }
    socketRead(data, expected: expected)
  }

  /// The production reader on a socket pair whose writer closed: the head or
  /// nothing, and the tunnel bytes still queued.
  static func socketRead(_ data: [UInt8], expected: Int?) {
    guard data.count <= 8 * 1024 else { return }
    var pair: [Int32] = [-1, -1]
    // socketpair writes the two descriptors into the borrowed array.
    guard unsafe socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return }
    defer { close(pair[0]) }
    var space: Int32 = 64 * 1024
    for fd in pair {
      _ = unsafe setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &space, socklen_t(MemoryLayout<Int32>.size))
      _ = unsafe setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &space, socklen_t(MemoryLayout<Int32>.size))
    }
    // send reads at most the borrowed bytes; recv below writes at most `rest`.
    let wrote = data.withUnsafeBytes { raw in
      unsafe raw.isEmpty ? 0 : send(pair[1], raw.baseAddress, raw.count, MSG_DONTWAIT)
    }
    close(pair[1])
    guard wrote == data.count else { return }
    let head = ConnectGate.readHead(pair[0], deadline: .seconds(5))
    guard let expected else {
      require(head.isEmpty, "an unfinished head is never returned")
      return
    }
    require(head == Array(data[0..<expected]), "readHead returns exactly the head")
    var rest = [UInt8](repeating: 0, count: data.count - expected + 1)
    let got = rest.withUnsafeMutableBytes { raw in
      unsafe recv(pair[0], raw.baseAddress, raw.count, MSG_DONTWAIT)
    }
    require(max(got, 0) == data.count - expected, "tunnel bytes stay on the socket")
    require(rest.prefix(max(got, 0)).elementsEqual(data[expected...]), "tunnel bytes unchanged")
  }
}
