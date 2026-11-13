import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#endif

/// One connection from a guest to its host owner's computer-use listener (vsock 7802), reopened
/// once when it fails.
package final class GuestCUConnection {
  private var fd: Int32 = -1
  private var reader: LineReader?

  package struct Unavailable: Error, CustomStringConvertible {
    package var description: String
  }

  package init() {}

  private func connectHost() throws {
    #if os(Linux)
      struct SockaddrVM {
        var family = sa_family_t(GuestCUConnection.afVsock)
        var reserved1: UInt16 = 0
        var port = GuestCUProtocol.port
        var cid: UInt32 = 2  // VMADDR_CID_HOST
        var flags: UInt8 = 0
        var zero: (UInt8, UInt8, UInt8) = (0, 0, 0)
      }
      let s = socket(Self.afVsock, Self.stream, 0)
      guard s >= 0 else { throw Unavailable(description: "no vsock socket") }
      var addr = SockaddrVM()
      let size = socklen_t(MemoryLayout<SockaddrVM>.size)
    #else
      let s = socket(AF_VSOCK, SOCK_STREAM, 0)
      guard s >= 0 else { throw Unavailable(description: "no vsock socket") }
      var addr = sockaddr_vm()
      addr.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
      addr.svm_family = sa_family_t(AF_VSOCK)
      addr.svm_cid = UInt32(VMADDR_CID_HOST)
      addr.svm_port = GuestCUProtocol.port
      let size = socklen_t(MemoryLayout<sockaddr_vm>.size)
    #endif
    let rc = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, size) }
    }
    guard rc == 0 else {
      close(s)
      throw Unavailable(
        description:
          "guest computer use is not enabled for this instance (vsock \(GuestCUProtocol.port) refused)"
      )
    }
    #if !os(Linux)
      var one: Int32 = 1
      setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    #endif
    fd = s
    reader = LineReader(fd: s, limit: GuestCUProtocol.maxResponse)
  }

  #if os(Linux)
    /// `AF_VSOCK` on Linux.
    static let afVsock: Int32 = 40
    #if canImport(Glibc)
      static let stream = Int32(SOCK_STREAM.rawValue)
    #else
      static let stream = SOCK_STREAM
    #endif
  #endif

  private func drop() {
    if fd >= 0 { close(fd) }
    fd = -1
    reader = nil
  }

  package func send(_ request: GuestCURequest) throws -> GuestCUResponse {
    var line = try JSONEncoder().encode(request)
    line.append(0x0A)
    for _ in 0..<2 {
      if fd < 0 { try connectHost() }
      let written = line.withUnsafeBytes { buf -> Bool in
        var off = 0
        while off < buf.count {
          let n = write(fd, buf.baseAddress! + off, buf.count - off)
          if n < 0, errno == EINTR { continue }
          if n <= 0 { return false }
          off += n
        }
        return true
      }
      if written, case .line(let reply)? = reader?.next(),
        let r = try? JSONDecoder().decode(GuestCUResponse.self, from: Data(reply))
      {
        return r
      }
      drop()
      if !request.mayResend(written: written) {
        throw Unavailable(
          description: "the reply was lost; the action may have been applied, so take a screenshot")
      }
    }
    throw Unavailable(description: "the host closed the computer-use connection")
  }
}

extension GuestCUMCP {
  /// The MCP server on stdin and stdout over a vsock connection to the host; returns when stdin
  /// closes. It holds no credentials and opens no other connection.
  package static func serveStdio() {
    signal(SIGPIPE, SIG_IGN)
    let connection = GuestCUConnection()
    let server = GuestCUMCP(send: { try connection.send($0) })
    var input = LineReader(fd: 0, limit: 1024 * 1024)
    while case .line(let line) = input.next() {
      guard !line.isEmpty, let reply = server.handle(line) else { continue }
      FileHandle.standardOutput.write(reply)
    }
  }
}
