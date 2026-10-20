import Foundation
import Synchronization

/// Launches and supervises the confined data-plane child (spec section 3):
/// `/usr/bin/sandbox-exec -p <DataPlaneSeatbelt.profile>` replaces itself
/// with `<iso-ci> _dataplane`, with an empty environment and only
/// stdin/stdout/stderr open (`POSIX_SPAWN_CLOEXEC_DEFAULT`). A self-test run
/// under the same profile must prove confinement first; otherwise preflight
/// service admission is refused with `CONFINEMENT_UNAVAILABLE`.
package final class DataPlaneSupervisor: DataPlaneEndpointLink, Sendable {
  package static let sandboxExec = "/usr/bin/sandbox-exec"
  package static let readyTimeout: Duration = .seconds(15)

  package struct Paths: Sendable {
    package let executable: String
    /// A path in the controller's private runtime directory. Its sibling
    /// directory `dp` holds the per-allocation endpoint sockets (the child
    /// binds nothing at this path itself); keep it short — Unix socket paths
    /// are limited to 104 bytes.
    package let socket: String
    package let staging: String
    /// A controller-private file the self-test must fail to read.
    package let probe: String

    package init(executable: String, socket: String, staging: String, probe: String) {
      self.executable = executable
      self.socket = socket
      self.staging = staging
      self.probe = probe
    }

    /// Where the child binds one socket per allocation.
    package var socketDirectory: String { (socket as NSString).deletingLastPathComponent + "/dp" }
  }

  /// Requests from the child the controller handles at once. A child that
  /// exceeds this is treated as compromised: it is stopped and the
  /// endpoint fails closed.
  package static let maxInFlightRequests = 128

  private struct State {
    var pid: pid_t = 0
    var exited = false
    var failure: CIError?
  }

  private let channel: DataPlaneChannel
  private let pending = DataPlanePendingCalls()
  private let state = Mutex(State())
  private let stderrTail = TailBuffer()
  private let inFlight = InFlightCounter()
  package let paths: Paths

  private init(channel: DataPlaneChannel, paths: Paths) {
    self.channel = channel
    self.paths = paths
  }

  /// Runs the self-test, starts the child, waits for `ready` and attaches
  /// it to `broker`.
  package static func launch(paths: Paths, broker: DataPlaneBroker) async throws(CIError)
    -> DataPlaneSupervisor
  {
    for path in [paths.executable, paths.staging, paths.socket] {
      guard path.hasPrefix("/"), !path.contains("\""), !path.contains("\n") else {
        throw CIError(.confinementUnavailable, "data-plane paths must be plain absolute paths")
      }
    }
    try PrivateFiles.ensureDirectory(paths.staging)
    try PrivateFiles.ensureDirectory(paths.socketDirectory)
    // The staging descriptors are opened before the child exists, so it
    // can never substitute the directories the controller reads and writes.
    try await broker.prepareStaging()
    try selfTest(paths)
    let (input, output, errors, pid) = try spawn(
      paths,
      arguments: [
        "_dataplane", "--sockets", paths.socketDirectory, "--staging", paths.staging,
      ])
    let supervisor = DataPlaneSupervisor(
      channel: DataPlaneChannel(input: output, output: input), paths: paths)
    supervisor.state.withLock { $0.pid = pid }
    supervisor.drain(errors)
    let (ready, readyContinuation) = AsyncStream.makeStream(of: Bool.self)
    supervisor.channel.startReading(
      onFrame: { [supervisor] frame in
        switch frame {
        case .ready: readyContinuation.yield(true)
        case .reply(let id, let result): supervisor.pending.resolve(id, result)
        case .request(let id, let allocation, let call):
          guard supervisor.inFlight.acquire(limit: maxInFlightRequests) else {
            supervisor.fail(
              CIError(.confinementUnavailable, "the data-plane child flooded the controller"))
            return
          }
          Task {
            defer { supervisor.inFlight.release() }
            let result: Result<JSONValue, CIError>
            do throws(CIError) { result = .success(try await broker.call(allocation, call)) } catch
            {
              result = .failure(error)
            }
            try? supervisor.channel.send(.reply(id: id, result: result))
          }
        case .event(let allocation, let event):
          Task { await broker.event(allocation, event) }
        case .register, .unregister, .cancel, .shutdown:
          // Only the controller sends these; a child that does is closed.
          supervisor.fail(CIError.invalid("unexpected frame from the data-plane child"))
        }
      },
      onClose: { [supervisor] error in
        readyContinuation.yield(false)
        supervisor.fail(error ?? CIError(.confinementUnavailable, "the data-plane child exited"))
      })
    let timeout = Task {
      try? await Task.sleep(for: readyTimeout)
      readyContinuation.yield(false)
    }
    var started = false
    for await value in ready {
      started = value
      break
    }
    timeout.cancel()
    guard started else {
      supervisor.terminate()
      throw supervisor.failure
        ?? CIError(.confinementUnavailable, "the data-plane child did not start")
    }
    do { try await broker.attach(supervisor, socketDirectory: paths.socketDirectory) } catch {
      supervisor.shutdown()
      throw error
    }
    return supervisor
  }

  package var failure: CIError? { state.withLock { $0.failure } }
  package var isRunning: Bool { state.withLock { !$0.exited && $0.failure == nil } }
  /// The last bytes the child wrote to stderr (bounded diagnostics).
  package var diagnostics: String {
    String(decoding: stderrTail.bytes.withLock { $0 }, as: UTF8.self)
  }

  private func fail(_ error: CIError) {
    state.withLock { if $0.failure == nil { $0.failure = error } }
    pending.close(error)
    terminate()
  }

  package func register(_ grant: DataPlaneGrant) async throws(CIError) -> String {
    if let failure { throw failure }
    let reply = try await pending.call { (id) throws(CIError) in
      try channel.send(.register(id: id, grant: grant))
    }
    // The broker composes and verifies the path; only the name travels.
    guard let name = reply["socket"]?.stringValue, DataPlaneBroker.isSocketName(name) else {
      throw CIError(.confinementUnavailable, "the data-plane child returned an invalid socket")
    }
    return name
  }

  package func unregister(_ allocation: AllocationID) async {
    try? channel.send(.unregister(allocation))
  }
  package func cancel(_ allocation: AllocationID) async { try? channel.send(.cancel(allocation)) }

  package func shutdown() {
    try? channel.send(.shutdown)
    terminate()
  }

  /// Signals the child once; reaps it on a background thread.
  package func terminate() {
    let pid = state.withLock { state -> pid_t in
      guard !state.exited, state.pid > 0 else { return 0 }
      state.exited = true
      return state.pid
    }
    guard pid > 0 else { return }
    kill(pid, SIGTERM)
    Thread.detachNewThread {
      var status: Int32 = 0
      for _ in 0..<50 {
        if waitpid(pid, &status, WNOHANG) == pid { return }
        Thread.sleep(forTimeInterval: 0.1)
      }
      kill(pid, SIGKILL)
      waitpid(pid, &status, 0)
    }
  }

  private func drain(_ fd: Int32) {
    Thread.detachNewThread { [stderrTail] in
      var buffer = [UInt8](repeating: 0, count: 4_096)
      while true {
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count < 0 && errno == EINTR { continue }
        if count <= 0 { break }
        stderrTail.bytes.withLock { tail in
          tail += buffer[0..<count]
          if tail.count > 4_096 { tail.removeFirst(tail.count - 4_096) }
        }
      }
      close(fd)
    }
  }

  // MARK: Confinement

  /// Arguments for `sandbox-exec` applying the profile to the executable.
  package static func sandboxArguments(_ paths: Paths, _ arguments: [String]) -> [String] {
    [
      sandboxExec, "-p", DataPlaneSeatbelt.profile, "-D", "EXE=\(paths.executable)",
      "-D", "STAGING=\(resolved(paths.staging))", "-D",
      "SOCKETS=\(resolved(paths.socketDirectory))",
      paths.executable,
    ] + arguments
  }

  /// Seatbelt matches real paths (`/var` is `/private/var`). `realpath(3)`
  /// keeps the `/private` prefix that `resolvingSymlinksInPath` strips.
  static func resolved(_ path: String) -> String {
    guard let real = realpath(path, nil) else { return path }
    defer { free(real) }
    return String(cString: real)
  }

  /// Runs `_dataplane --jail-selftest` under the profile and requires a
  /// `{"confined":true,…}` report and exit status 0.
  package static func selfTest(_ paths: Paths) throws(CIError) {
    let listener = LoopbackListener()
    defer { listener.close() }
    let (input, output, errors, pid) = try spawn(
      paths,
      arguments: [
        "_dataplane", "--jail-selftest", "--staging", paths.staging, "--probe", paths.probe,
        "--tcp-port", String(listener.port),
      ])
    close(input)
    close(errors)
    var report: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while report.count < 64 << 10 {
      let count = buffer.withUnsafeMutableBytes { read(output, $0.baseAddress, $0.count) }
      if count < 0 && errno == EINTR { continue }
      if count <= 0 { break }
      report += buffer[0..<count]
    }
    close(output)
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    let line = report.split(separator: 0x0A).last.map(Array.init) ?? []
    guard status == 0,
      let value = try? StrictJSON.parse(line, limits: JSONLimits(maxBytes: 64 << 10)),
      value["confined"] == .bool(true)
    else {
      throw CIError(
        .confinementUnavailable,
        "the data-plane confinement self-test failed; preflight service is not admitted",
        details: ["report": String(decoding: line.prefix(512), as: UTF8.self)])
    }
  }

  /// posix_spawn of sandbox-exec with an empty environment and only the
  /// three standard descriptors. Returns (child stdin writer, child stdout
  /// reader, child stderr reader, pid).
  static func spawn(_ paths: Paths, arguments: [String]) throws(CIError) -> (
    Int32, Int32, Int32, pid_t
  ) {
    var stdinPipe: [Int32] = [0, 0]
    var stdoutPipe: [Int32] = [0, 0]
    var stderrPipe: [Int32] = [0, 0]
    guard pipe(&stdinPipe) == 0, pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
      throw CIError(.confinementUnavailable, "cannot create the data-plane channel")
    }
    for fd in [stdinPipe[1], stdoutPipe[0], stderrPipe[0]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], 0)
    posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], 1)
    posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], 2)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // Every descriptor other than 0-2 is closed in the child.
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
    let argv = sandboxArguments(paths, arguments).map { strdup($0) } + [nil]
    defer { for pointer in argv { free(pointer) } }
    let envp: [UnsafeMutablePointer<CChar>?] = [nil]
    var pid: pid_t = 0
    let result = posix_spawn(&pid, sandboxExec, &actions, &attributes, argv, envp)
    close(stdinPipe[0])
    close(stdoutPipe[1])
    close(stderrPipe[1])
    guard result == 0 else {
      for fd in [stdinPipe[1], stdoutPipe[0], stderrPipe[0]] { close(fd) }
      throw CIError(.confinementUnavailable, "cannot start the confined data-plane child")
    }
    return (stdinPipe[1], stdoutPipe[0], stderrPipe[0], pid)
  }
}

/// A loopback TCP listener for the self-test's positive network probe: the
/// confined child must be unable to connect to it.
final class LoopbackListener {
  let fd: Int32
  let port: UInt16

  init() {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    self.fd = fd
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
    }
    listen(fd, 1)
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    port = UInt16(bigEndian: address.sin_port)
  }

  func close() { Darwin.close(fd) }
}

final class TailBuffer: Sendable {
  let bytes = Mutex<[UInt8]>([])
}

/// A bounded in-flight counter (lock-protected).
final class InFlightCounter: Sendable {
  let count = Mutex(0)

  func acquire(limit: Int) -> Bool {
    count.withLock { value in
      guard value < limit else { return false }
      value += 1
      return true
    }
  }

  func release() { count.withLock { $0 -= 1 } }
}
