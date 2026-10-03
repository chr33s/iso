import Darwin
import Testing

@testable import IsoEgressCore

private func answers(_ values: [String?]) -> ResolvedAddresses? {
  var head: UnsafeMutablePointer<addrinfo>?
  for value in values.reversed() {
    let node = UnsafeMutablePointer<addrinfo>.allocate(capacity: 1)
    node.initialize(to: addrinfo())
    node.pointee.ai_family = AF_INET
    node.pointee.ai_socktype = SOCK_STREAM
    node.pointee.ai_addrlen = socklen_t(MemoryLayout<sockaddr_in>.size)
    if let value {
      let address = UnsafeMutablePointer<sockaddr_in>.allocate(capacity: 1)
      address.initialize(to: sockaddr_in())
      address.pointee.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.pointee.sin_family = sa_family_t(AF_INET)
      address.pointee.sin_port = UInt16(443).bigEndian
      address.pointee.sin_addr = in_addr(s_addr: inet_addr(value))
      node.pointee.ai_addr = UnsafeMutableRawPointer(address).assumingMemoryBound(to: sockaddr.self)
    }
    node.pointee.ai_next = head
    head = node
  }
  return ResolvedAddresses.adopting(head, status: 0) { head in
    var cursor: UnsafeMutablePointer<addrinfo>? = head
    while let node = cursor {
      cursor = node.pointee.ai_next
      if let address = node.pointee.ai_addr {
        UnsafeMutableRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).deallocate()
      }
      node.deallocate()
    }
  }
}

@Test func publicConnectorResolvesEveryRequestAndNeverDialsForbiddenAnswers() {
  let sequence: [[String?]] = [
    ["8.8.8.8"], ["8.8.8.8", "1.1.1.1"], ["127.0.0.1"], ["8.8.8.8", "10.0.0.1"],
    ["10.0.0.1", "8.8.8.8"], ["1.1.1.1"], ["8.8.8.8", nil],
    [nil, "8.8.8.8"], [], ["9.9.9.9"],
  ]
  var lookups = 0
  var localReads = 0
  var dialed: [String] = []
  var results: [Int32?] = []
  for expected in sequence {
    results.append(
      PublicConnector.connect(
        "approved.example",
        local: {
          localReads += 1
          return ["1.1.1.1"]
        },
        resolve: { host in
          #expect(host == "approved.example")
          lookups += 1
          return answers(expected)
        },
        dial: { info, local in
          #expect(local == ["1.1.1.1"])
          if let address = PublicConnector.numeric(info) { dialed.append(address) }
          return 123  // Sentinel; this fixture never creates a socket.
        }))
  }
  // The mixed public/host-local answer must also fail as a whole, even after
  // this same hostname previously resolved to an approved public address.
  #expect(results == [123, nil, nil, nil, nil, nil, nil, nil, nil, 123])
  #expect(dialed == ["8.8.8.8", "9.9.9.9"])
  #expect(lookups == sequence.count && localReads == sequence.count)
}

@Test func publicConnectorPinsFirstNumericAnswerAndPropagatesDialFailure() {
  var dialed: [String] = []
  for result: Int32? in [123, nil] {
    let fd = PublicConnector.connect(
      "approved.example", local: { [] },
      resolve: { _ in
        answers(["8.8.8.8", "9.9.9.9"])
      },
      dial: { info, _ in
        if let address = PublicConnector.numeric(info) { dialed.append(address) }
        return result
      })
    #expect(fd == result)
  }
  #expect(dialed == ["8.8.8.8", "8.8.8.8"])
}
