// `iso-macos-helper cu-mcp`: the computer-use MCP server a guest agent runs
// (docs/design/guest-driven-computer-use.md §6). It reads MCP messages on
// stdin, asks the host owner over vsock 7802, and writes replies on stdout.
// It holds no credentials and opens no other connection.

import Darwin
import Foundation
import IsoMacProtocol

/// One connection to the host's guest computer-use listener, reopened once
/// when it fails.
final class GuestCUConnection {
  private var fd: Int32 = -1
  private var reader: LineReader?

  struct Unavailable: Error, CustomStringConvertible {
    var description: String
  }

  private func connectHost() throws {
    let s = socket(AF_VSOCK, SOCK_STREAM, 0)
    guard s >= 0 else { throw Unavailable(description: "no vsock socket") }
    var addr = sockaddr_vm()
    addr.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
    addr.svm_family = sa_family_t(AF_VSOCK)
    addr.svm_cid = UInt32(VMADDR_CID_HOST)
    addr.svm_port = GuestCUProtocol.port
    let rc = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(s, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
      }
    }
    guard rc == 0 else {
      close(s)
      throw Unavailable(
        description:
          "guest computer use is not enabled for this instance (vsock \(GuestCUProtocol.port) refused)"
      )
    }
    var one: Int32 = 1
    setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    fd = s
    reader = LineReader(fd: s, limit: GuestCUProtocol.maxResponse)
  }

  private func drop() {
    if fd >= 0 { close(fd) }
    fd = -1
    reader = nil
  }

  func send(_ request: GuestCURequest) throws -> GuestCUResponse {
    var line = try JSONEncoder().encode(request)
    line.append(0x0A)
    for attempt in 0..<2 {
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
      if attempt == 1 { break }
    }
    throw Unavailable(description: "the host closed the computer-use connection")
  }
}

/// The stdio loop; returns when stdin closes.
func runComputerUseMCP() {
  signal(SIGPIPE, SIG_IGN)
  let connection = GuestCUConnection()
  let server = GuestCUMCP(send: { try connection.send($0) })
  var input = LineReader(fd: 0, limit: 1024 * 1024)
  while case .line(let line) = input.next() {
    guard !line.isEmpty, let reply = server.handle(line) else { continue }
    FileHandle.standardOutput.write(reply)
  }
}
