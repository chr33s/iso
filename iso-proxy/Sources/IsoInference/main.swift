import Darwin
import Dispatch
import Foundation
import IsoInferenceGateway
import NIOPosix

/// `iso-inference --state-dir DIR --relay-dir DIR --backend-port PORT...
/// [--jail-selftest]`
///
/// The per-user inference gateway. `iso` starts it under `sandbox-exec`
/// with the gateway Seatbelt profile; it refuses to run unconfined. The
/// state directory (owner-only) holds the control socket, the startup lock,
/// the outstanding-work journal and the audit log. Session sockets are
/// bound in the relay directory (owner-only), where the sandbox runtime
/// relays them into guests over vsock.
enum Exit: Int32 {
  case ok = 0
  case failure = 1
  case usage = 2
  /// Another gateway holds the startup lock.
  case alreadyRunning = 3
}

func log(_ message: String) {
  FileHandle.standardError.write(Data(("iso-inference: " + message + "\n").utf8))
}

/// The state and relay directories, the backend ports the launch profile
/// allows (the gateway refuses registrations naming any other), and
/// self-test mode.
func arguments() -> (
  stateDirectory: String, relayDirectory: String, ports: Set<UInt16>, selftest: Bool
)? {
  var rest = Array(CommandLine.arguments.dropFirst())[...]
  var directory: String?
  var relay: String?
  var ports = Set<UInt16>()
  var selftest = false
  while let flag = rest.popFirst() {
    switch flag {
    case "--jail-selftest": selftest = true
    case "--state-dir":
      guard directory == nil, let value = rest.popFirst(), value.hasPrefix("/") else { return nil }
      directory = value
    case "--relay-dir":
      guard relay == nil, let value = rest.popFirst(), value.hasPrefix("/") else { return nil }
      relay = value
    case "--backend-port":
      guard let value = rest.popFirst(), let port = UInt16(value), port >= 1024 else { return nil }
      ports.insert(port)
    default: return nil
    }
  }
  guard let directory, let relay, !ports.isEmpty else { return nil }
  return (directory, relay, ports, selftest)
}

/// The state and relay directories must be real directories owned by this
/// user and closed to everyone else.
func checkPrivateDirectory(_ path: String) -> Bool {
  var info = stat()
  guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
    info.st_mode & 0o077 == 0
  else { return false }
  return true
}

func main() -> Exit {
  umask(0o077)
  // Every socket is written with SO_NOSIGPIPE or through NIO; this is a
  // backstop so a peer that disappears never kills the gateway.
  signal(SIGPIPE, SIG_IGN)
  guard let (stateDirectory, relayDirectory, ports, selftest) = arguments() else {
    log(
      "usage: iso-inference --state-dir ABSOLUTE_DIR --relay-dir ABSOLUTE_DIR --backend-port PORT... [--jail-selftest]"
    )
    return .usage
  }
  guard checkPrivateDirectory(stateDirectory), checkPrivateDirectory(relayDirectory) else {
    log("state and relay directories must be owner-only (0700) directories owned by this user")
    return .failure
  }
  do {
    try Jail.disableCoreDumps()
    try Jail.requireConfinement(
      stateDirectory: stateDirectory, relayDirectory: relayDirectory, backendPorts: ports)
  } catch {
    log("confinement check failed: \(error)")
    return .failure
  }
  if selftest {
    log(
      "jail self-test: writes outside the state and relay directories, TCP listeners, exec, non-loopback egress and unlisted loopback ports denied"
    )
    return .ok
  }
  let lock = open(stateDirectory + "/gateway.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
  guard lock >= 0 else {
    log("cannot open the startup lock")
    return .failure
  }
  guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
    close(lock)
    return errno == EWOULDBLOCK ? .alreadyRunning : .failure
  }
  let done = DispatchSemaphore(value: 0)
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
  let gateway: Gateway
  let control: ControlServer
  do {
    let journal = try Journal(directory: stateDirectory + "/journal")
    let audit = AuditLog(path: stateDirectory + "/audit.log")
    gateway = Gateway(
      group: group, journal: journal, audit: audit, relayDirectory: relayDirectory,
      backendPorts: ports, onExit: { done.signal() })
    control = try ControlServer(path: stateDirectory + "/control.sock", gateway: gateway)
  } catch {
    log("startup failed: \(error)")
    return .failure
  }
  let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
    source.setEventHandler { done.signal() }
    source.resume()
    return source
  }
  Thread { control.run() }.start()
  gateway.startTicker()
  log("ready (epoch \(gateway.epoch))")
  done.wait()
  control.stop()
  try? gateway.prepareShutdown(force: true)
  for source in signals { source.cancel() }
  try? group.syncShutdownGracefully()
  log("stopped")
  return .ok
}

exit(main().rawValue)
