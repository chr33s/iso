import Darwin
import Foundation
import IsoProxyTestSupport

final class LoopbackSocket {
  let fd: Int32
  init() throws {
    fd = socket(AF_INET, SOCK_STREAM, 0)
    try check(fd >= 0, "socket creation")
    do {
      var timeout = timeval(tv_sec: 1, tv_usec: 0)
      var enabled: Int32 = 1
      for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
        try check(
          setsockopt(fd, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
          "socket timeout")
      }
      try check(
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, 4) == 0, "socket SIGPIPE protection")
    } catch {
      Darwin.close(fd)
      throw error
    }
  }
  func close() { Darwin.close(fd) }
  func address<T>(port: UInt16, _ operation: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        operation($0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
  }
  func connect(port: UInt16) throws {
    let result = address(port: port) { Darwin.connect(fd, $0, $1) }
    try check(result == 0, "loopback connect failed: \(errno)")
  }
  func send(_ text: String) throws {
    let bytes = Array(text.utf8)
    try bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.send(
          fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
        if count < 0 && errno == EINTR { continue }
        try check(count > 0, "loopback write failed")
        offset += count
      }
    }
  }
  func receive() throws -> Data {
    var response = Data()
    var bytes = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = recv(fd, &bytes, bytes.count, 0)
      if count == 0 { return response }
      if count < 0 && errno == EINTR { continue }
      if count < 0 && errno == ECONNRESET { return response }
      try check(count > 0, "loopback read deadline/error: \(errno)")
      response.append(contentsOf: bytes.prefix(count))
      try check(response.count <= 65536, "unbounded local response")
    }
  }
}

func freePort() throws -> UInt16 {
  let socket = try LoopbackSocket()
  defer { socket.close() }
  try check(socket.address(port: 0) { Darwin.bind(socket.fd, $0, $1) } == 0, "loopback bind")
  var address = sockaddr_in()
  var length = socklen_t(MemoryLayout<sockaddr_in>.size)
  let result = withUnsafeMutablePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket.fd, $0, &length) }
  }
  try check(result == 0, "getsockname")
  return UInt16(bigEndian: address.sin_port)
}

func request(
  _ port: UInt16, headers: String = "", target: String = "/v1/messages", host: String = "guest"
) throws -> Data {
  let socket = try LoopbackSocket()
  defer { socket.close() }
  try socket.connect(port: port)
  try socket.send("GET \(target) HTTP/1.1\r\nHost: \(host)\r\n\(headers)Connection: close\r\n\r\n")
  return try socket.receive()
}
