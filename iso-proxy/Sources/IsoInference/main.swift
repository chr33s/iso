import Darwin
import Dispatch
import Foundation
import IsoInferenceCore
import IsoInferenceGateway
import IsoProxyCore
import NIOPosix

/// `iso-inference --state-dir DIR --relay-dir DIR --backend-port PORT...
/// [--jail-selftest]`
///
/// The per-user inference broker. `iso` starts it under `sandbox-exec`
/// with the gateway Seatbelt profile; it refuses to run unconfined. The
/// state directory (owner-only) holds the control socket, the worker
/// socket, the startup lock, the outstanding-work journal and the audit
/// log. It parses no guest bytes: each session is served by its own worker.
///
/// `iso-inference --worker --broker PATH --socket PATH --session ID
/// [--jail-selftest]`, with the session's one-time key on stdin
///
/// One session's worker (§5.1). `iso` starts it under the worker profile,
/// which admits only that session's socket, its backend ports and the
/// broker's worker socket. It binds the session socket in the relay
/// directory, where the sandbox runtime relays it into the guest.
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
  // lstat writes the one record borrowed here; the C path is borrowed too.
  guard unsafe lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
    info.st_mode & 0o077 == 0
  else { return false }
  return true
}

/// The worker's broker socket, session socket and session, and self-test mode.
func workerArguments() -> (broker: String, socket: String, session: String, selftest: Bool)? {
  var rest = Array(CommandLine.arguments.dropFirst())[...]
  guard rest.popFirst() == "--worker" else { return nil }
  var broker: String?
  var socket: String?
  var session: String?
  var selftest = false
  while let flag = rest.popFirst() {
    switch flag {
    case "--jail-selftest": selftest = true
    case "--broker":
      guard broker == nil, let value = rest.popFirst(), value.hasPrefix("/") else { return nil }
      broker = value
    case "--socket":
      guard socket == nil, let value = rest.popFirst(), value.hasPrefix("/"),
        !value.split(separator: "/").contains("..")
      else { return nil }
      socket = value
    case "--session":
      guard session == nil, let value = rest.popFirst(), value.utf8.count == 32,
        value.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) })
      else { return nil }
      session = value
    default: return nil
    }
  }
  guard let broker, let socket, let session else { return nil }
  return (broker, socket, session, selftest)
}

/// The worker's key: 64 lowercase hex digits on stdin, nothing else.
func readKey() -> String? {
  var bytes: [UInt8] = []
  var byte: UInt8 = 0
  // read writes one byte into the local borrowed for each call.
  while bytes.count <= 65, unsafe read(0, &byte, 1) == 1 { bytes.append(byte) }
  if bytes.last == 0x0A { bytes.removeLast() }
  guard bytes.count == 64,
    bytes.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) })
  else { return nil }
  return String(decoding: bytes, as: UTF8.self)
}

func workerMain(broker: String, socket: String, session: String, selftest: Bool) -> Exit {
  do {
    try Jail.disableCoreDumps()
    try Jail.requireWorkerConfinement(socketPath: socket)
  } catch {
    log("worker confinement check failed: \(error)")
    return .failure
  }
  if selftest {
    log(
      "worker jail self-test: writes beside the session socket, TCP listeners, exec, non-loopback egress, other loopback ports, the home directory and other processes' information denied"
    )
    return .ok
  }
  guard let key = readKey() else {
    log("worker: no key on stdin")
    return .usage
  }
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
  for number in [SIGINT, SIGTERM] { signal(number, SIG_DFL) }
  do {
    let worker = try SessionWorker.start(
      broker: broker, socketPath: socket, sessionID: session, key: key, group: group)
    worker.run()
  } catch {
    log("worker startup failed: \(error)")
    try? group.syncShutdownGracefully()
    return .failure
  }
  try? group.syncShutdownGracefully()
  return .ok
}

func main() -> Exit {
  umask(0o077)
  signal(SIGPIPE, SIG_IGN)
  if CommandLine.arguments.dropFirst().first == "--worker" {
    guard let (broker, socket, session, selftest) = workerArguments() else {
      log(
        "usage: iso-inference --worker --broker ABSOLUTE_PATH --socket ABSOLUTE_PATH --session ID [--jail-selftest]"
      )
      return .usage
    }
    return workerMain(broker: broker, socket: socket, session: session, selftest: selftest)
  }
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
      "jail self-test: writes outside the state directory, TCP listeners, exec, every network connection, the home directory and other processes' information denied"
    )
    return .ok
  }
  // The C path is borrowed for the call only.
  let lock = unsafe open(stateDirectory + "/gateway.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
  guard lock >= 0 else {
    log("cannot open the startup lock")
    return .failure
  }
  guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
    close(lock)
    return errno == EWOULDBLOCK ? .alreadyRunning : .failure
  }
  // Every shared connection, its upstream socket and the session listeners
  // must fit; a launchd default of 256 would not hold them.
  do { try DescriptorLimit.raise(to: SessionLimits.descriptors) } catch {
    log("cannot raise the open-file limit: \(error)")
    return .failure
  }
  let done = DispatchSemaphore(value: 0)
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
  let gateway: Gateway
  let control: ControlServer
  let workers: WorkerServer
  do {
    let journal = try Journal(directory: stateDirectory + "/journal")
    let audit = AuditLog(path: stateDirectory + "/audit.log")
    gateway = Gateway(
      group: group, journal: journal, audit: audit, relayDirectory: relayDirectory,
      backendPorts: ports, workers: WorkerRegistry(), onExit: { done.signal() })
    workers = try WorkerServer(path: stateDirectory + "/workers.sock", gateway: gateway)
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
  // Control frames are parsed on this thread; its stack bounds their nesting.
  let controlThread = Thread { control.run() }
  controlThread.stackSize = 8 << 20
  controlThread.start()
  // Worker frames are parsed on per-link threads, from the worker socket.
  Thread { workers.run() }.start()
  gateway.startTicker()
  log("ready (epoch \(gateway.epoch))")
  done.wait()
  control.stop()
  workers.stop()
  try? gateway.prepareShutdown(force: true)
  for source in signals { source.cancel() }
  try? group.syncShutdownGracefully()
  log("stopped")
  return .ok
}

exit(main().rawValue)
