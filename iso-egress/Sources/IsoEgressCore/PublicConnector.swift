import Darwin

/// Resolve afresh for every connection, validate the entire answer, and dial
/// the selected numeric address without a second hostname lookup.
package enum PublicConnector {
  package static func connect(_ host: String, admission: Admission) -> Int32? {
    connect(
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
    return resolved.withAddressInfo { info in
      var cursor: UnsafePointer<addrinfo>? = info
      var addresses: [String] = []
      while let node = cursor {
        guard let text = numeric(node) else { return nil }
        addresses.append(text)
        cursor = node.pointee.ai_next.map { UnsafePointer($0) }
      }
      guard AddressChoice.firstPublic(addresses, local: local) != nil else { return nil }
      return dial(info, local)
    }
  }

  private static func dial(_ info: UnsafePointer<addrinfo>, _ local: Set<String>) -> Int32? {
    guard let first = info.pointee.ai_addr else { return nil }
    let fd = socket(info.pointee.ai_family, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    guard Dial.connect(fd, address: first, length: info.pointee.ai_addrlen),
      Dial.peerIsPublic(fd, local: local)
    else {
      close(fd)
      return nil
    }
    return fd
  }

  static func numeric(_ node: UnsafePointer<addrinfo>) -> String? {
    guard let address = node.pointee.ai_addr else { return nil }
    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    guard
      getnameinfo(
        address, node.pointee.ai_addrlen, &buffer,
        socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0
    else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}
