import CryptoKit
import Darwin
import Foundation
import Security
import Virtualization

/// A preinstalled VM bundle (spec §6.1). The same hardware model, machine
/// identifier, auxiliary storage and disk are reused across every context.
struct VMBundle {
  let root: URL
  var disk: URL { root.appendingPathComponent("disk.img") }
  var aux: URL { root.appendingPathComponent("aux.img") }
  var hardwareModel: URL { root.appendingPathComponent("hardware-model.bin") }
  var machineID: URL { root.appendingPathComponent("machine-id.bin") }
  var mac: URL { root.appendingPathComponent("mac.txt") }
  var helperKeyFile: URL { root.appendingPathComponent("helper.key") }

  /// 32-byte key, hex, shared with the guest helper (see `BootIdentity`).
  var helperKey: SymmetricKey? {
    guard
      let hex = try? String(contentsOf: helperKeyFile, encoding: .utf8)
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

  var macAddress: String? {
    (try? String(contentsOf: mac, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// Fixed geometry, no automatic reconfiguration (spec §6.2). 80 ppi keeps the
/// guest at backing scale 1, so guest points equal framebuffer pixels.
let displayWidth = 1440
let displayHeight = 900
let displayPPI = 80
let vsockPort: UInt32 = 7701

struct ConfigurationError: Error, CustomStringConvertible {
  let description: String
}

func makeConfiguration(_ b: VMBundle, cpus: Int, memoryGiB: UInt64) throws
  -> VZVirtualMachineConfiguration
{
  guard let hwData = try? Data(contentsOf: b.hardwareModel),
    let hw = VZMacHardwareModel(dataRepresentation: hwData),
    let midData = try? Data(contentsOf: b.machineID),
    let mid = VZMacMachineIdentifier(dataRepresentation: midData)
  else {
    throw ConfigurationError(description: "bundle \(b.root.path) lacks hardware model / machine id")
  }
  guard hw.isSupported else {
    throw ConfigurationError(description: "hardware model not supported on this host")
  }

  let platform = VZMacPlatformConfiguration()
  platform.hardwareModel = hw
  platform.machineIdentifier = mid
  platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: b.aux)

  let c = VZVirtualMachineConfiguration()
  c.platform = platform
  c.bootLoader = VZMacOSBootLoader()
  c.cpuCount = cpus
  c.memorySize = memoryGiB << 30

  let gfx = VZMacGraphicsDeviceConfiguration()
  gfx.displays = [
    VZMacGraphicsDisplayConfiguration(
      widthInPixels: displayWidth, heightInPixels: displayHeight, pixelsPerInch: displayPPI)
  ]
  c.graphicsDevices = [gfx]
  c.storageDevices = [
    VZVirtioBlockDeviceConfiguration(
      attachment: try VZDiskImageStorageDeviceAttachment(url: b.disk, readOnly: false))
  ]
  let net = VZVirtioNetworkDeviceConfiguration()
  net.attachment = VZNATNetworkDeviceAttachment()
  if let s = b.macAddress, let m = VZMACAddress(string: s) { net.macAddress = m }
  c.networkDevices = [net]
  c.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
  c.keyboards = [VZMacKeyboardConfiguration()]
  c.socketDevices = [VZVirtioSocketDeviceConfiguration()]
  c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
  return c
}

func stateName(_ s: VZVirtualMachine.State) -> String {
  switch s {
  case .stopped: "stopped"
  case .running: "running"
  case .paused: "paused"
  case .error: "error"
  case .starting: "starting"
  case .pausing: "pausing"
  case .resuming: "resuming"
  case .stopping: "stopping"
  case .saving: "saving"
  case .restoring: "restoring"
  @unknown default: "unknown(\(s.rawValue))"
  }
}

// MARK: - Boot identity

/// Guest helper hellos over vsock, authenticated by challenge-response: on
/// connect the host sends `nonce <hex>`, and the hello must carry
/// `mac = HMAC-SHA256(key, "<nonce>|<boot>")` using the per-bundle helper key
/// (`helper.key`, root-only inside the guest). A guest process without the key
/// cannot supply or replace the boot identity, or take over the shutdown
/// channel. `generation` bumps on every accepted hello and every disconnect of
/// the accepted connection, so a session bound to one generation dies with it.
final class BootIdentity: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var _hello: [String: Any]?
  private var _generation = 0
  private var _active: Int = 0  // id of the authenticated connection; 0 when none
  private var _writeFD: Int32 = -1
  // The listener contract: keep the accepted connection alive while it is in use.
  private var _connection: VZVirtioSocketConnection?
  private var _pending = 0
  private var nextID = 0
  let log: EventLog
  let key: SymmetricKey?

  init(log: EventLog, key: SymmetricKey?) {
    self.log = log
    self.key = key
  }

  var hello: [String: Any]? { lock.withLock { _hello } }
  var bootID: String? { hello?["boot"] as? String }
  var generation: Int { lock.withLock { _generation } }

  func reset() { lock.withLock { _hello = nil } }

  /// Ask the guest helper (root, in the guest) to run `shutdown -h now`.
  func requestGuestShutdown() -> Bool {
    lock.withLock {
      guard _writeFD >= 0 else { return false }
      let line = Array("shutdown\n".utf8)
      return write(_writeFD, line, line.count) == line.count
    }
  }

  static func mac(key: SymmetricKey, nonce: String, boot: String) -> String {
    HMAC<SHA256>.authenticationCode(for: Data("\(nonce)|\(boot)".utf8), using: key)
      .map { String(format: "%02x", $0) }.joined()
  }

  func listener(
    _ listener: VZVirtioSocketListener, shouldAcceptNewConnection conn: VZVirtioSocketConnection,
    from device: VZVirtioSocketDevice
  ) -> Bool {
    // Bounded: unauthenticated guest connections cannot pile up threads.
    let id: Int? = lock.withLock {
      guard _pending < 4 else { return nil }
      _pending += 1
      nextID += 1
      return nextID
    }
    guard let id else {
      log.emit("guest_hello_rejected", ["reason": "too many pending connections"])
      return false
    }
    let fd = dup(conn.fileDescriptor)
    nonisolated(unsafe) let conn = conn
    Thread.detachNewThread { [self] in
      var tv = timeval(tv_sec: 10, tv_usec: 0)
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
      var nonceBytes = [UInt8](repeating: 0, count: 16)
      _ = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
      let nonce = nonceBytes.map { String(format: "%02x", $0) }.joined()
      let challenge = Array("nonce \(nonce)\n".utf8)
      _ = write(fd, challenge, challenge.count)

      var buf = [UInt8](repeating: 0, count: 1024)
      var line = Data()
      var accepted = false
      // A total deadline for the hello: the per-read timeout alone would let a
      // keyless guest process hold a pending slot by trickling bytes.
      let helloDeadline = Date().addingTimeInterval(10)
      reading: while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        if accepted { continue }  // only the first line means anything; hold until EOF
        if Date() > helloDeadline {
          log.emit("guest_hello_rejected", ["reason": "hello deadline exceeded"])
          break
        }
        line.append(contentsOf: buf[0..<n])
        if line.count > 16384 { break }  // bounded: guest bytes are untrusted
        guard let nl = line.firstIndex(of: 0x0A) else { continue }
        let reason = authenticate(line[..<nl], nonce: nonce)
        guard case .success(let obj) = reason else {
          if case .failure(let why) = reason {
            log.emit("guest_hello_rejected", ["reason": why.description])
          }
          break reading
        }
        // Accepted: this connection replaces any earlier one.
        let wfd = dup(fd)
        lock.withLock {
          if _writeFD >= 0 { close(_writeFD) }
          _writeFD = wfd
          _connection = conn
          _active = id
          _hello = obj
          _generation += 1
          _pending -= 1
        }
        accepted = true
        tv = timeval(tv_sec: 0, tv_usec: 0)  // now hold for the life of the boot
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        log.emit(
          "guest_hello",
          [
            "boot_id": obj["boot"] ?? NSNull(), "build": obj["build"] ?? NSNull(),
            "product_version": obj["product_version"] ?? NSNull(),
            "fixture": obj["fixture"] ?? NSNull(), "authenticated": true,
          ])
      }
      close(fd)
      let wasActive = lock.withLock { () -> Bool in
        guard accepted else {
          _pending -= 1
          return false
        }
        guard _active == id else { return false }
        _active = 0
        _hello = nil
        _generation += 1
        if _writeFD >= 0 { close(_writeFD) }
        _writeFD = -1
        _connection = nil
        return true
      }
      if wasActive { log.emit("guest_helper_disconnected") }
    }
    return true
  }

  private struct AuthError: Error, CustomStringConvertible {
    let description: String
  }

  private func authenticate(_ msg: Data, nonce: String) -> Result<[String: Any], AuthError> {
    guard let obj = try? JSONSerialization.jsonObject(with: msg) as? [String: Any],
      obj["hello"] as? Int == 1, let boot = obj["boot"] as? String, boot.count <= 64
    else { return .failure(AuthError(description: "malformed hello")) }
    guard let key else { return .failure(AuthError(description: "no helper key in bundle")) }
    guard let mac = obj["mac"] as? String,
      mac == BootIdentity.mac(key: key, nonce: nonce, boot: boot)
    else { return .failure(AuthError(description: "bad mac")) }
    return .success(obj)
  }
}

// MARK: - Guest network

/// The guest's NAT DHCP lease for `mac`, from the host's world-readable lease file.
func guestIP(mac: String) -> String? {
  let want = mac.lowercased().split(separator: ":").map { p -> String in
    let s = p.drop { $0 == "0" }
    return s.isEmpty ? "0" : String(s)
  }.joined(separator: ":")
  guard let text = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8) else {
    return nil
  }
  var ip: String?
  for block in text.components(separatedBy: "}") {
    var fields: [String: String] = [:]
    for line in block.split(separator: "\n") {
      let parts = line.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
      if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
    }
    if let hw = fields["hw_address"],
      hw.split(separator: ",", maxSplits: 1).last.map(String.init) == want
    {
      ip = fields["ip_address"]
    }
  }
  return ip
}

/// Connect to `ip:22` from this process and read the SSH identification line.
/// Subject to macOS Local Network privacy: an unapproved process gets
/// EHOSTUNREACH (65) for the NAT guest. Recorded as a finding, not used as the oracle.
func sshBannerDirect(ip: String, timeoutMs: Int32 = 3000) -> String? {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  guard fd >= 0 else { return nil }
  defer { close(fd) }
  var addr = sockaddr_in()
  addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  addr.sin_family = sa_family_t(AF_INET)
  addr.sin_port = in_port_t(22).bigEndian
  guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return nil }
  _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
  let rc = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  if rc != 0 && errno != EINPROGRESS { return nil }
  var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
  guard poll(&pfd, 1, timeoutMs) == 1 else {
    errno = ETIMEDOUT
    return nil
  }
  var err: Int32 = 0
  var len = socklen_t(MemoryLayout<Int32>.size)
  getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
  guard err == 0 else {
    errno = err
    return nil
  }
  pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
  guard poll(&pfd, 1, timeoutMs) == 1 else {
    errno = ETIMEDOUT
    return nil
  }
  var buf = [UInt8](repeating: 0, count: 256)
  let n = read(fd, &buf, buf.count)
  guard n > 0 else {
    errno = n == 0 ? ECONNRESET : errno
    return nil
  }
  let s = String(decoding: buf[0..<n], as: UTF8.self)
  guard s.hasPrefix("SSH-") else {
    errno = EPROTO
    return nil
  }
  return String(s.prefix { $0 != "\r" && $0 != "\n" })
}

/// The SSH identification line via `/usr/bin/nc`, a platform binary that Local
/// Network privacy does not gate. No credentials are used.
func sshBanner(ip: String) -> String? {
  let r = runTool(["/usr/bin/nc", "-G", "3", "-w", "3", ip, "22"], timeout: 8)
  let line = r.output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
  return line.hasPrefix("SSH-") ? line.trimmingCharacters(in: .whitespacesAndNewlines) : nil
}

/// errno from a direct connect to ip:22 (0 on success).
func directConnectErrno(ip: String) -> Int {
  if sshBannerDirect(ip: ip) != nil { return 0 }
  return Int(errno)
}
