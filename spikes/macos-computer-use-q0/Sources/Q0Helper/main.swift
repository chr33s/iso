// q0helper — guest boot-identity helper. Connects to host vsock port 7700 and
// sends {"hello":1,"boot":"<kern.bootsessionuuid>"}, then holds the connection
// for the life of the boot. Reconnects with backoff if the host owner restarts.

import Darwin
import Foundation

func bootSessionUUID() -> String {
  var size = 0
  sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0)
  var buf = [UInt8](repeating: 0, count: max(size, 1))
  sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0)
  return String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
}

let boot = bootSessionUUID()
while true {
  let fd = socket(AF_VSOCK, SOCK_STREAM, 0)
  var addr = sockaddr_vm()
  addr.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
  addr.svm_family = sa_family_t(AF_VSOCK)
  addr.svm_cid = UInt32(VMADDR_CID_HOST)
  addr.svm_port = 7700
  let rc = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(fd, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
    }
  }
  if rc == 0 {
    let hello = "{\"hello\":1,\"boot\":\"\(boot)\"}\n"
    _ = hello.withCString { write(fd, $0, strlen($0)) }
    var b = [UInt8](repeating: 0, count: 64)
    while read(fd, &b, b.count) > 0 {}
  }
  close(fd)
  sleep(2)
}
