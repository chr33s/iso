// iso-vz-probe-helper — guest boot-identity helper, installed as a guest
// LaunchDaemon (root) so it runs before any guest login.
//
//   iso-vz-probe-helper <fixture-state.json> <key-file>
//
// Connects to host vsock port 7701, reads the host's `nonce <hex>` challenge
// and answers with one line, then holds the connection for the life of the
// boot (reconnecting if the host owner restarts):
//   {"hello":1,"boot":"<kern.bootsessionuuid>","product_version":"27.0.1",
//    "build":"26A434","fixture":<state.json identity fields or null>,
//    "mac":"<HMAC-SHA256(key, nonce|boot)>"}
// The key file (hex, mode 0600 root) proves the hello comes from this daemon,
// not from another guest process. The host may send "shutdown\n" to request a
// guest-initiated shutdown.

import CryptoKit
import Darwin
import Foundation

let port: UInt32 = 7701

func sysctlString(_ name: String) -> String {
  var size = 0
  sysctlbyname(name, nil, &size, nil, 0)
  var buf = [UInt8](repeating: 0, count: max(size, 1))
  sysctlbyname(name, &buf, &size, nil, 0)
  return String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
}

let args = CommandLine.arguments
let statePath = args.count > 1 ? args[1] : nil
let keyPath = args.count > 2 ? args[2] : "/usr/local/etc/iso-vz-probe-helper.key"

func loadKey() -> SymmetricKey? {
  guard
    let hex = try? String(contentsOfFile: keyPath, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines), hex.count == 64
  else { return nil }
  var bytes: [UInt8] = []
  var i = hex.startIndex
  while i < hex.endIndex {
    let j = hex.index(i, offsetBy: 2)
    guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
    bytes.append(b)
    i = j
  }
  return SymmetricKey(data: bytes)
}

func hello(nonce: String, key: SymmetricKey) -> Data {
  var fixture: Any = NSNull()
  if let statePath, let d = FileManager.default.contents(atPath: statePath), d.count <= 8192,
    let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
  {
    fixture = obj.filter { ["run_token", "frame_counter", "pid"].contains($0.key) }
  }
  let boot = sysctlString("kern.bootsessionuuid")
  let mac = HMAC<SHA256>.authenticationCode(for: Data("\(nonce)|\(boot)".utf8), using: key)
    .map { String(format: "%02x", $0) }.joined()
  let msg: [String: Any] = [
    "hello": 1, "boot": boot, "product_version": sysctlString("kern.osproductversion"),
    "build": sysctlString("kern.osversion"), "fixture": fixture, "mac": mac,
  ]
  var d = (try? JSONSerialization.data(withJSONObject: msg, options: [.sortedKeys])) ?? Data()
  d.append(0x0A)
  return d
}

/// One line from `fd`, at most 256 bytes.
func readLine(_ fd: Int32) -> String? {
  var out = [UInt8]()
  var c: UInt8 = 0
  while out.count < 256 {
    guard read(fd, &c, 1) == 1 else { return nil }
    if c == 0x0A { return String(decoding: out, as: UTF8.self) }
    out.append(c)
  }
  return nil
}

while true {
  guard let key = loadKey() else {
    sleep(5)
    continue
  }
  let fd = socket(AF_VSOCK, SOCK_STREAM, 0)
  var addr = sockaddr_vm()
  addr.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
  addr.svm_family = sa_family_t(AF_VSOCK)
  addr.svm_cid = UInt32(VMADDR_CID_HOST)
  addr.svm_port = port
  let rc = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(fd, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
    }
  }
  if rc == 0, let challenge = readLine(fd), challenge.hasPrefix("nonce ") {
    let line = hello(nonce: String(challenge.dropFirst(6)), key: key)
    line.withUnsafeBytes { _ = write(fd, $0.baseAddress!, $0.count) }
    while let cmd = readLine(fd) {
      if cmd == "shutdown" {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/shutdown")
        p.arguments = ["-h", "now"]
        try? p.run()
      }
    }
  }
  close(fd)
  sleep(2)
}
