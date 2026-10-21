import Darwin

/// Resolve afresh for every connection, validate the entire answer, and dial
/// its numeric addresses in answer order without a second hostname lookup.
/// An answer with any non-public address is refused whole; a validated
/// address that does not connect (an IPv6 answer on a host without an IPv6
/// route) falls through to the next validated one.
package enum PublicConnector {
  package static func connect(_ host: String, admission: Admission) -> Int32? {
    unsafe connect(
      host, local: HostAddresses.current,
      resolve: {
        Resolver.lookup($0, admission: admission)
      }, dial: dial)
  }

  static func connect(
    _ host: String, local: () -> Set<String>, resolve: (String) -> ResolvedAddresses?,
    dial: (UnsafePointer<addrinfo>, Set<String>) -> Int32?
  ) -> Int32? {
    let local = local()
    guard let resolved = resolve(host) else { return nil }
    // The libc list is borrowed for this closure only and walked by ai_next.
    return unsafe resolved.withAddressInfo { info in
      var cursor: UnsafePointer<addrinfo>? = unsafe info
      var addresses: [String] = []
      while let node = unsafe cursor {
        guard let text = unsafe numeric(node) else { return nil }
        addresses.append(text)
        unsafe cursor = node.pointee.ai_next.map { unsafe UnsafePointer($0) }
      }
      guard AddressChoice.firstPublic(addresses, local: local) != nil else { return nil }
      var candidate: UnsafePointer<addrinfo>? = unsafe info
      while let node = unsafe candidate {
        if let fd = unsafe dial(node, local) { return fd }
        unsafe candidate = node.pointee.ai_next.map { unsafe UnsafePointer($0) }
      }
      return nil
    }
  }

  private static func dial(_ info: UnsafePointer<addrinfo>, _ local: Set<String>) -> Int32? {
    // ai_addr is valid for ai_addrlen bytes while the list is borrowed.
    guard let first = unsafe info.pointee.ai_addr else { return nil }
    let fd = socket(unsafe info.pointee.ai_family, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    guard unsafe Dial.connect(fd, address: first, length: info.pointee.ai_addrlen),
      Dial.peerIsPublic(fd, local: local)
    else {
      close(fd)
      return nil
    }
    return fd
  }

  static func numeric(_ node: UnsafePointer<addrinfo>) -> String? {
    guard let address = unsafe node.pointee.ai_addr else { return nil }
    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    // getnameinfo reads ai_addrlen bytes and writes a NUL-terminated NI_MAXHOST name.
    guard
      unsafe getnameinfo(
        address, node.pointee.ai_addrlen, &buffer,
        socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0
    else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}
