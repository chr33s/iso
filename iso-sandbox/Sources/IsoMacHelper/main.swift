// iso-macos-helper — the guest side of a macOS sandbox's management channel.
// Installed in the template as a root LaunchDaemon, so it runs before login.
//
// It connects to the host owner on vsock port 7801 and answers its
// challenge (see IsoMacProtocol and docs/design/macos-guest-computer-use.md).
// It acts only on the closed message set: enroll (first boot of a clone),
// network, status, shutdown. It runs no other commands.

import Darwin
import Foundation
import IsoMacProtocol

let helperVersion = "1"
let stateDir = "/var/db/iso-macos-helper"
let keyPath = stateDir + "/key"
let guestUser = "iso"
let sshDir = "/etc/ssh"

func log(_ s: String) {
  FileHandle.standardError.write(Data("iso-macos-helper: \(s)\n".utf8))
}

func sysctlString(_ name: String) -> String {
  var size = 0
  sysctlbyname(name, nil, &size, nil, 0)
  var buf = [UInt8](repeating: 0, count: max(size, 1))
  sysctlbyname(name, &buf, &size, nil, 0)
  return String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
}

/// Runs a fixed tool with an argv; never a shell.
@discardableResult
func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: path)
  p.arguments = args
  p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
  let pipe = Pipe()
  p.standardOutput = pipe
  p.standardError = pipe
  p.standardInput = FileHandle.nullDevice
  do { try p.run() } catch { return (-1, "\(error)") }
  let out = pipe.fileHandleForReading.readDataToEndOfFile()
  p.waitUntilExit()
  return (p.terminationStatus, String(decoding: out.prefix(8192), as: UTF8.self))
}

func loadKey() -> HelperKey? {
  (try? String(contentsOfFile: keyPath, encoding: .utf8)).flatMap { HelperKey(hex: $0) }
}

/// Writes `contents` to `path` atomically with `mode`, owned by `uid:gid`.
func writePrivate(_ path: String, _ contents: String, mode: mode_t, uid: uid_t = 0, gid: gid_t = 0)
  throws
{
  let tmp = path + ".tmp-\(getpid())"
  let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, mode)
  guard fd >= 0 else { throw HelperError.unexpected("open \(tmp): errno \(errno)") }
  let bytes = Array(contents.utf8)
  let ok = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) == $0.count }
  fchown(fd, uid, gid)
  fchmod(fd, mode)
  fsync(fd)
  close(fd)
  guard ok, rename(tmp, path) == 0 else {
    unlink(tmp)
    throw HelperError.unexpected("write \(path)")
  }
}

func ensureDir(_ path: String, mode: mode_t, uid: uid_t = 0, gid: gid_t = 0) throws {
  if mkdir(path, mode) != 0, errno != EEXIST {
    throw HelperError.unexpected("mkdir \(path): errno \(errno)")
  }
  var st = stat()
  guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
    throw HelperError.unexpected("\(path) is not a directory")
  }
  chown(path, uid, gid)
  chmod(path, mode)
}

func hostKey() -> String? {
  (try? String(contentsOfFile: sshDir + "/ssh_host_ed25519_key.pub", encoding: .utf8))
    .map { SSHPublicKey.canonical($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    .flatMap { SSHPublicKey.isEd25519($0) ? $0 : nil }
}

/// First boot of a clone: store the helper key, authorize the host's SSH key
/// for `iso`, and generate this clone's own SSH host keys.
func enroll(_ m: HelperMessage) throws -> String {
  guard let keyHex = m.key, let key = HelperKey(hex: keyHex), let authorized = m.authorizedKey
  else { throw HelperError.malformed }
  guard let pw = getpwnam(guestUser) else { throw HelperError.unexpected("no user \(guestUser)") }
  let uid = pw.pointee.pw_uid
  let gid = pw.pointee.pw_gid
  let home = String(cString: pw.pointee.pw_dir)
  try ensureDir(home + "/.ssh", mode: 0o700, uid: uid, gid: gid)
  try writePrivate(
    home + "/.ssh/authorized_keys", authorized + "\n", mode: 0o600, uid: uid, gid: gid)
  // Fresh host keys for this clone; the template ships none.
  for name in (try? FileManager.default.contentsOfDirectory(atPath: sshDir)) ?? []
  where name.hasPrefix("ssh_host_") {
    unlink(sshDir + "/" + name)
  }
  let gen = run("/usr/bin/ssh-keygen", ["-A"])
  guard gen.status == 0, let pub = hostKey() else {
    throw HelperError.unexpected("ssh-keygen -A failed: \(gen.output)")
  }
  // The key is written last: until it exists the clone is not enrolled.
  try ensureDir(stateDir, mode: 0o700)
  try writePrivate(keyPath, key.hex + "\n", mode: 0o600)
  return pub
}

func applyNetwork(_ n: HelperNetwork) throws {
  guard n.isWellFormed else { throw HelperError.malformed }
  // The service bound to en0, the VM's only network device.
  let order = run("/usr/sbin/networksetup", ["-listnetworkserviceorder"])
  var service: String?
  var last: String?
  for line in order.output.split(separator: "\n") {
    let s = String(line)
    if s.hasPrefix("("), let close = s.firstIndex(of: ")"), s.index(after: close) < s.endIndex,
      !s.hasPrefix("(Hardware")
    {
      last = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces)
    } else if s.contains("Device: en0") {
      service = last
    }
  }
  guard let service, !service.isEmpty else { throw HelperError.unexpected("no service for en0") }
  let set = run("/usr/sbin/networksetup", ["-setmanual", service, n.address, n.netmask, n.gateway])
  guard set.status == 0 else { throw HelperError.unexpected("setmanual: \(set.output)") }
  let dns = run(
    "/usr/sbin/networksetup", ["-setdnsservers", service] + (n.dns.isEmpty ? ["Empty"] : n.dns))
  guard dns.status == 0 else { throw HelperError.unexpected("setdnsservers: \(dns.output)") }
}

func send(_ fd: Int32, _ m: HelperMessage) -> Bool {
  let line = m.encodedLine()
  return line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) == $0.count }
}

func reply(_ type: HelperMessage.Kind, message: String? = nil, to request: HelperMessage? = nil)
  -> HelperMessage
{
  var m = HelperMessage(type: type)
  m.message = message
  m.id = request?.id
  return m
}

/// One connection: challenge, hello, then host requests until EOF.
func session(_ fd: Int32) {
  var reader = LineReader(fd: fd)
  guard case .line(let first) = reader.next(),
    case .success(let challenge) = HelperMessage.parse(first),
    challenge.type == .challenge, let nonce = challenge.nonce, nonce.count == 32
  else { return }
  let boot = sysctlString("kern.bootsessionuuid")
  var key = loadKey()
  var hello = HelperMessage(type: .hello)
  hello.boot = boot
  hello.build = sysctlString("kern.osversion")
  hello.productVersion = sysctlString("kern.osproductversion")
  hello.helperVersion = helperVersion
  hello.enrolled = key != nil
  hello.mac = key.map { HelperProtocol.mac(key: $0, nonce: nonce, boot: boot) }
  guard send(fd, hello) else { return }

  while case .line(let line) = reader.next() {
    guard case .success(let m) = HelperMessage.parse(line) else {
      _ = send(fd, reply(.error, message: "malformed"))
      return
    }
    switch m.type {
    // Only the host can send `enroll` (the helper dials the host's vsock
    // listener), and only while its record is pending: a key left by an
    // interrupted enrollment is replaced.
    case .enroll:
      do {
        let pub = try enroll(m)
        key = loadKey()
        var r = HelperMessage(type: .enrolled)
        r.sshHostKey = pub
        r.mac = key.map { HelperProtocol.mac(key: $0, nonce: nonce, boot: boot) }
        guard send(fd, r) else { return }
      } catch {
        _ = send(fd, reply(.error, message: "\(error)"))
        return
      }
    case .network where key != nil:
      guard let n = m.network else { return }
      do {
        try applyNetwork(n)
        _ = send(fd, reply(.ack, to: m))
      } catch {
        _ = send(fd, reply(.error, message: "\(error)", to: m))
      }
    case .status where key != nil:
      var r = reply(.statusReply, to: m)
      r.sshHostKey = hostKey()
      _ = send(fd, r)
    case .shutdown where key != nil:
      _ = send(fd, reply(.ack, to: m))
      run("/sbin/shutdown", ["-h", "now"])
    default:
      // Requests before enrollment, or guest-side types.
      _ = send(fd, reply(.error, message: "unexpected \(m.type.rawValue)"))
      return
    }
  }
}

signal(SIGPIPE, SIG_IGN)
while true {
  let fd = socket(AF_VSOCK, SOCK_STREAM, 0)
  var addr = sockaddr_vm()
  addr.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
  addr.svm_family = sa_family_t(AF_VSOCK)
  addr.svm_cid = UInt32(VMADDR_CID_HOST)
  addr.svm_port = HelperProtocol.port
  let rc = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(fd, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
    }
  }
  if rc == 0 { session(fd) }
  close(fd)
  sleep(2)
}
