import Foundation

/// The one subprocess launcher (S-03). Every child is spawned from an
/// explicit argv (no shell interpolation by this layer), in its own process
/// group, with an explicit environment. Captured mode drains stdout and stderr
/// together so neither pipe can fill and block the child, bounds what it keeps,
/// enforces a deadline, and always reaps the child and closes its descriptors
/// before returning — including on every error path.
package struct ProcessRunner: Sendable {
  package struct Request: Sendable {
    package var executable: String
    package var arguments: [String]
    package var environment: [String: String]
    package var workingDirectory: String?
    package var deadline: Duration
    /// Bytes kept per stream.
    package var outputLimit: Int
    package var overflow: OverflowPolicy
    /// Polled while the child runs; `true` kills it (`cancelled`). Only long
    /// create/boot/build calls are cancellable, so cleanup after Ctrl-C
    /// still runs to completion.
    package var isCancelled: (@Sendable () -> Bool)?
    /// Bytes written to the child's stdin, which is then closed (EOF).
    /// Secrets go here, never on argv. Nil leaves stdin at `/dev/null`.
    package var input: [UInt8]?

    package init(
      executable: String, arguments: [String], environment: [String: String],
      workingDirectory: String? = nil, deadline: Duration, outputLimit: Int = 1 << 20,
      overflow: OverflowPolicy = .fail, input: [UInt8]? = nil
    ) {
      self.input = input
      self.executable = executable
      self.arguments = arguments
      self.environment = environment
      self.workingDirectory = workingDirectory
      self.deadline = deadline
      self.outputLimit = outputLimit
      self.overflow = overflow
    }
  }

  /// What happens when a stream exceeds `outputLimit`.
  package enum OverflowPolicy: Sendable, Equatable {
    /// Kill the child and fail with `outputLimitExceeded`.
    case fail
    /// Keep the first `outputLimit` bytes, drain the rest so the child can
    /// finish, and report `truncated`. For runtime calls, whose effect must
    /// not be cut short by the caller's reading limit.
    case drain
  }

  package enum Termination: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)
  }

  package struct Output: Sendable {
    package let termination: Termination
    package let stdout: [UInt8]
    package let stderr: [UInt8]
    /// A stream exceeded the limit under `.drain`; the output is incomplete.
    package let truncated: Bool
  }

  package enum Failure: Error, Equatable, Sendable {
    case spawn(errno: Int32)
    case timedOut
    case outputLimitExceeded
    case io(errno: Int32)
    case cancelled
  }

  package init() {}

  /// Runs to completion with captured output; stdin is `input` or `/dev/null`.
  package func capture(_ request: Request) throws(Failure) -> Output {
    var buffers: [[UInt8]] = [[], []]
    var truncated = false
    let termination = try pump(request, deadline: request.deadline) {
      (stream, bytes) throws(Failure) in
      let room = request.outputLimit - buffers[stream.rawValue].count
      if bytes.count > room {
        guard request.overflow == .drain else { throw .outputLimitExceeded }
        truncated = true
      }
      bytes.extracting(first: max(room, 0)).withUnsafeBufferPointer {
        buffers[stream.rawValue].append(contentsOf: $0)
      }
    }
    return Output(
      termination: termination, stdout: buffers[0], stderr: buffers[1], truncated: truncated)
  }

  package enum Stream: Int, Sendable {
    case stdout = 0
    case stderr = 1
  }

  /// Streaming mode: each chunk goes to `onOutput` as it arrives, with no
  /// buffering beyond one read. `deadline` nil means none (log following).
  /// A throwing sink stops the run; the child is then killed and reaped.
  package func stream(
    _ request: Request, deadline: Duration?,
    onOutput: (Stream, ArraySlice<UInt8>) throws(Failure) -> Void
  ) throws(Failure) -> Termination {
    try pump(request, deadline: deadline) { (stream, bytes) throws(Failure) in
      // Public sinks receive owned slices that they may retain after this read.
      let owned = bytes.withUnsafeBufferPointer { Array($0) }
      try onOutput(stream, owned[...])
    }
  }

  /// Spawn, drain both pipes concurrently until EOF, then reap. The child's
  /// process group is killed on every early exit.
  private func pump(
    _ request: Request, deadline: Duration?,
    sink: (Stream, Span<UInt8>) throws(Failure) -> Void
  ) throws(Failure) -> Termination {
    var stdoutPipe: [Int32] = [-1, -1]
    var stderrPipe: [Int32] = [-1, -1]
    guard pipe(&stdoutPipe) == 0 else { throw .spawn(errno: errno) }
    guard pipe(&stderrPipe) == 0 else {
      let code = errno
      close(stdoutPipe[0])
      close(stdoutPipe[1])
      throw .spawn(errno: code)
    }
    var parentEnds = [stdoutPipe[0], stderrPipe[0]]
    defer { for fd in parentEnds where fd >= 0 { close(fd) } }
    for fd in parentEnds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    var stdinPipe: [Int32] = [-1, -1]
    if request.input != nil {
      guard pipe(&stdinPipe) == 0 else {
        let code = errno
        close(stdoutPipe[1])
        close(stderrPipe[1])
        throw .spawn(errno: code)
      }
      _ = fcntl(stdinPipe[1], F_SETFD, FD_CLOEXEC)
      _ = fcntl(stdinPipe[1], F_SETFL, fcntl(stdinPipe[1], F_GETFL) | O_NONBLOCK)
      _ = fcntl(stdinPipe[1], F_SETNOSIGPIPE, 1)
    }
    var writer = stdinPipe[1]
    defer { if writer >= 0 { close(writer) } }

    let pid: pid_t
    do {
      defer {
        close(stdoutPipe[1])
        close(stderrPipe[1])
        if stdinPipe[0] >= 0 { close(stdinPipe[0]) }
      }
      pid = try spawn(
        request, stdin: stdinPipe[0] >= 0 ? .descriptor(stdinPipe[0]) : .null,
        stdout: .descriptor(stdoutPipe[1]), stderr: .descriptor(stderrPipe[1]), ownGroup: true)
    }
    var pending = request.input ?? []
    var written = 0
    if writer >= 0 && pending.isEmpty {
      close(writer)
      writer = -1
    }
    var child = ChildProcess(pid: pid)
    defer { child.killGroupAndReap() }

    let start = ContinuousClock.now
    var chunk = InlineArray<16384, UInt8>(repeating: 0)
    while parentEnds.contains(where: { $0 >= 0 }) {
      if request.isCancelled?() == true { throw .cancelled }
      var timeout: Int32 = -1
      if let deadline {
        let remaining = deadline - (ContinuousClock.now - start)
        guard remaining > .zero else { throw .timedOut }
        timeout = Int32(clamping: remaining.milliseconds)
      }
      var fds = parentEnds.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
      fds.append(pollfd(fd: writer, events: Int16(POLLOUT), revents: 0))
      if request.isCancelled != nil { timeout = timeout < 0 ? 50 : min(timeout, 50) }
      let ready = poll(&fds, nfds_t(fds.count), timeout)
      if ready < 0 {
        if errno == EINTR { continue }
        throw .io(errno: errno)
      }
      if writer >= 0 && fds[2].revents != 0 {
        // The child may exit without reading its input (EPIPE): stop
        // writing and let its exit status speak.
        let count = pending[written...].withUnsafeBytes { write(writer, $0.baseAddress, $0.count) }
        if count > 0 { written += count }
        if (count < 0 && errno != EAGAIN && errno != EINTR) || written == pending.count {
          close(writer)
          writer = -1
          pending = []
        }
      }
      for index in parentEnds.indices where fds[index].fd >= 0 && fds[index].revents != 0 {
        let count = withUnsafeMutableBytes(of: &chunk) {
          read(fds[index].fd, $0.baseAddress, $0.count)
        }
        if count < 0 {
          if errno == EINTR || errno == EAGAIN { continue }
          throw .io(errno: errno)
        }
        if count == 0 {
          close(parentEnds[index])
          parentEnds[index] = -1
          continue
        }
        try sink(Stream(rawValue: index)!, chunk.span.extracting(first: count))
      }
    }
    guard let deadline else { return child.waitIndefinitely() }
    guard let termination = child.wait(until: deadline - (ContinuousClock.now - start)) else {
      throw .timedOut
    }
    return termination
  }

  /// Attached mode, for interactive and pass-through commands: stdout and
  /// stderr are the caller's own, stdin is the caller's (`inherit`) or
  /// `input`, and the child stays in the caller's process group so a
  /// terminal session keeps its TTY and job control. No deadline: `ssh`
  /// bounds its own connection. Waits for the child to exit.
  package func attached(_ request: Request, inheritStdin: Bool) throws(Failure) -> Termination {
    var stdinPipe: [Int32] = [-1, -1]
    if let input = request.input {
      guard pipe(&stdinPipe) == 0 else { throw .spawn(errno: errno) }
      _ = fcntl(stdinPipe[1], F_SETFD, FD_CLOEXEC)
      _ = fcntl(stdinPipe[1], F_SETNOSIGPIPE, 1)
      let pid: pid_t
      do {
        defer { close(stdinPipe[0]) }
        pid = try spawn(
          request, stdin: .descriptor(stdinPipe[0]), stdout: .descriptor(1),
          stderr: .descriptor(2), ownGroup: false)
      } catch {
        close(stdinPipe[1])
        throw error
      }
      var child = ChildProcess(pid: pid, ownsGroup: false)
      defer { child.killGroupAndReap() }
      // Blocking write; a child that exits early yields EPIPE, not SIGPIPE.
      var offset = 0
      while offset < input.count {
        let count = input[offset...].withUnsafeBytes {
          write(stdinPipe[1], $0.baseAddress, $0.count)
        }
        if count < 0 {
          if errno == EINTR { continue }
          break
        }
        offset += count
      }
      close(stdinPipe[1])
      return child.waitIndefinitely()
    }
    let pid = try spawn(
      request, stdin: inheritStdin ? .descriptor(0) : .null, stdout: .descriptor(1),
      stderr: .descriptor(2), ownGroup: false)
    var child = ChildProcess(pid: pid, ownsGroup: false)
    defer { child.killGroupAndReap() }
    guard let isCancelled = request.isCancelled else { return child.waitIndefinitely() }
    while true {
      if let termination = child.wait(until: .milliseconds(50)) { return termination }
      if isCancelled() {
        // The child shares our process group (job control), so its own
        // children (rsync's receiver, ssh) are reaped by pid, before their
        // parent's death reparents them out of reach.
        for pid in Self.descendants(of: child.pid).reversed() { kill(pid, SIGKILL) }
        throw .cancelled
      }
    }
  }

  /// Every live descendant of `pid`, parents before their children.
  static func descendants(of pid: pid_t) -> [pid_t] {
    var found: [pid_t] = []
    var pending = [pid]
    while let parent = pending.popLast() {
      var buffer = [pid_t](repeating: 0, count: 256)
      // Returns the number of pids written, not bytes.
      let count = proc_listchildpids(
        parent, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
      guard count > 0 else { continue }
      let children = buffer.prefix(Int(count)).filter { $0 > 0 }
      found += children
      pending += children
    }
    return found
  }

  /// Both ends of a two-process pipeline (`tar cf - | ssh …`).
  package struct PipelineOutput: Sendable {
    package let producer: Termination
    package let consumer: Termination
    package let producerStderr: [UInt8]
    package let consumerStderr: [UInt8]
  }

  /// `producer`'s stdout feeds `consumer`'s stdin through a kernel pipe;
  /// both stderr streams are drained concurrently (so neither child can
  /// block on a full pipe) and kept up to `outputLimit`; stdout of the
  /// consumer and stdin of the producer are `/dev/null`. No deadline: a
  /// transfer takes as long as the data does, and `ssh` bounds a dead
  /// connection itself. Both children are reaped before this returns.
  package func pipeline(_ producer: Request, _ consumer: Request) throws(Failure) -> PipelineOutput
  {
    var link: [Int32] = [-1, -1]
    var producerErr: [Int32] = [-1, -1]
    var consumerErr: [Int32] = [-1, -1]
    var opened: [Int32] = []
    defer { for fd in opened where fd >= 0 { close(fd) } }
    for index in 0..<3 {
      var fds: [Int32] = [-1, -1]
      guard pipe(&fds) == 0 else { throw .spawn(errno: errno) }
      opened += fds
      for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
      switch index {
      case 0: link = fds
      case 1: producerErr = fds
      default: consumerErr = fds
      }
    }
    func closeOpened(_ fd: Int32) {
      if let index = opened.firstIndex(of: fd) {
        close(fd)
        opened[index] = -1
      }
    }
    let producerPID = try spawn(
      producer, stdin: .null, stdout: .descriptor(link[1]), stderr: .descriptor(producerErr[1]),
      ownGroup: true)
    var producerChild = ChildProcess(pid: producerPID)
    defer { producerChild.killGroupAndReap() }
    closeOpened(link[1])
    closeOpened(producerErr[1])
    let consumerPID = try spawn(
      consumer, stdin: .descriptor(link[0]), stdout: .null, stderr: .descriptor(consumerErr[1]),
      ownGroup: true)
    var consumerChild = ChildProcess(pid: consumerPID)
    defer { consumerChild.killGroupAndReap() }
    closeOpened(link[0])
    closeOpened(consumerErr[1])

    var ends = [producerErr[0], consumerErr[0]]
    var buffers: [[UInt8]] = [[], []]
    var chunk = InlineArray<16384, UInt8>(repeating: 0)
    let isCancelled = producer.isCancelled ?? consumer.isCancelled
    while ends.contains(where: { $0 >= 0 }) {
      if isCancelled?() == true { throw .cancelled }
      var fds = ends.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
      if poll(&fds, nfds_t(fds.count), isCancelled == nil ? -1 : 50) < 0 {
        if errno == EINTR { continue }
        throw .io(errno: errno)
      }
      for index in fds.indices where fds[index].fd >= 0 && fds[index].revents != 0 {
        let count = withUnsafeMutableBytes(of: &chunk) {
          read(fds[index].fd, $0.baseAddress, $0.count)
        }
        if count < 0 {
          if errno == EINTR || errno == EAGAIN { continue }
          throw .io(errno: errno)
        }
        if count == 0 {
          closeOpened(ends[index])
          ends[index] = -1
          continue
        }
        let limit = index == 0 ? producer.outputLimit : consumer.outputLimit
        let room = limit - buffers[index].count
        chunk.span.extracting(first: min(count, max(room, 0))).withUnsafeBufferPointer {
          buffers[index].append(contentsOf: $0)
        }
      }
    }
    return PipelineOutput(
      producer: producerChild.waitIndefinitely(), consumer: consumerChild.waitIndefinitely(),
      producerStderr: buffers[0], consumerStderr: buffers[1])
  }

  enum ChildDescriptor {
    case null
    case descriptor(Int32)
  }

  private func spawn(
    _ request: Request, stdin: ChildDescriptor, stdout: ChildDescriptor, stderr: ChildDescriptor,
    ownGroup: Bool
  ) throws(Failure) -> pid_t {
    var actions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    for (target, source) in [(Int32(0), stdin), (1, stdout), (2, stderr)] {
      switch source {
      case .null:
        posix_spawn_file_actions_addopen(
          &actions, target, "/dev/null", target == 0 ? O_RDONLY : O_WRONLY, 0)
      case .descriptor(let fd) where fd == target:
        // Keep an inherited standard descriptor across CLOEXEC_DEFAULT.
        posix_spawn_file_actions_addinherit_np(&actions, fd)
      case .descriptor(let fd):
        posix_spawn_file_actions_adddup2(&actions, fd, target)
      }
    }
    if let directory = request.workingDirectory {
      posix_spawn_file_actions_addchdir(&actions, directory)
    }
    var attributes: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    if ownGroup { posix_spawnattr_setpgroup(&attributes, 0) }
    var signals = sigset_t()
    sigemptyset(&signals)
    posix_spawnattr_setsigmask(&attributes, &signals)
    sigfillset(&signals)
    posix_spawnattr_setsigdefault(&attributes, &signals)
    // Own process group: a deadline kills the whole tree, not just `sh`.
    // CLOEXEC_DEFAULT: only the three standard descriptors reach the child.
    posix_spawnattr_setflags(
      &attributes,
      Int16(
        (ownGroup ? POSIX_SPAWN_SETPGROUP : 0) | POSIX_SPAWN_CLOEXEC_DEFAULT
          | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

    let argv = [request.executable] + request.arguments
    let environment = request.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    var pid: pid_t = 0
    let result = withCStrings(argv) { argvPointer in
      withCStrings(environment) { envPointer in
        posix_spawn(&pid, request.executable, &actions, &attributes, argvPointer, envPointer)
      }
    }
    guard result == 0 else { throw .spawn(errno: result) }
    return pid
  }
}

/// Reaps a spawned child exactly once. `killGroupAndReap` is the scoped
/// cleanup: it is a no-op after a successful `wait`.
struct ChildProcess: ~Copyable {
  let pid: pid_t
  /// Whether the child leads its own process group (never the caller's).
  let ownsGroup: Bool
  private var reaped = false

  init(pid: pid_t, ownsGroup: Bool = true) {
    self.pid = pid
    self.ownsGroup = ownsGroup
    if ownsGroup { ChildGroups.register(pid) }
  }

  mutating func markReaped() {
    reaped = true
    if ownsGroup { ChildGroups.unregister(pid) }
  }

  mutating func wait(until remaining: Duration) -> ProcessRunner.Termination? {
    let start = ContinuousClock.now
    while true {
      var status: Int32 = 0
      let result = waitpid(pid, &status, WNOHANG)
      if result == pid {
        markReaped()
        return Self.decode(status)
      }
      if result < 0 && errno != EINTR {
        markReaped()
        return .exited(-1)
      }
      if ContinuousClock.now - start >= remaining { return nil }
      usleep(5_000)
    }
  }

  mutating func waitIndefinitely() -> ProcessRunner.Termination {
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 {
      if errno != EINTR {
        markReaped()
        return .exited(-1)
      }
    }
    markReaped()
    return Self.decode(status)
  }

  mutating func killGroupAndReap() {
    guard !reaped else { return }
    if ownsGroup { kill(-pid, SIGKILL) }
    kill(pid, SIGKILL)
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    markReaped()
  }

  static func decode(_ status: Int32) -> ProcessRunner.Termination {
    let signal = status & 0x7F
    return signal == 0 ? .exited((status >> 8) & 0xFF) : .signaled(signal)
  }
}

extension Duration {
  var milliseconds: Int64 {
    let (seconds, attoseconds) = components
    // Saturates: `--builder-timeout` accepts up to Int64.max seconds.
    let (milliseconds, overflow) = seconds.multipliedReportingOverflow(by: 1000)
    if overflow { return seconds < 0 ? .min : .max }
    let (total, overflowAdding) = milliseconds.addingReportingOverflow(
      attoseconds / 1_000_000_000_000_000)
    return overflowAdding ? .max : total
  }
}

func withCStrings<R>(
  _ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R
) -> R {
  let pointers = strings.map { strdup($0) } + [nil]
  defer { for pointer in pointers { free(pointer) } }
  return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}

/// Splits a byte stream into `\n`-terminated lines, holding at most `limit`
/// bytes of any one line: the rest of a longer line is dropped and
/// ` [line truncated]` appended, so a guest cannot make the host buffer an
/// unbounded line. A final line without a newline is emitted by `finish`.
package struct BoundedLineSplitter: Sendable {
  package static let truncatedMarker = Array(" [line truncated]".utf8)
  let limit: Int
  var line: [UInt8] = []
  var truncated = false

  package init(limit: Int) { self.limit = limit }

  package mutating func feed(_ bytes: ArraySlice<UInt8>, _ emit: ([UInt8]) throws -> Void) rethrows
  {
    var rest = bytes
    while let newline = rest.firstIndex(of: UInt8(ascii: "\n")) {
      append(rest[rest.startIndex..<newline])
      try emit(take())
      rest = rest[rest.index(after: newline)...]
    }
    append(rest)
  }

  package mutating func finish(_ emit: ([UInt8]) throws -> Void) rethrows {
    if !line.isEmpty || truncated { try emit(take()) }
  }

  mutating func append(_ bytes: ArraySlice<UInt8>) {
    let room = limit - line.count
    if bytes.count > room { truncated = true }
    line.append(contentsOf: bytes.prefix(max(room, 0)))
  }

  mutating func take() -> [UInt8] {
    var out = line
    if truncated { out += Self.truncatedMarker }
    line = []
    truncated = false
    return out
  }
}

extension ProcessRunner.Termination: CustomStringConvertible {
  /// Rust `ExitStatus` Display text: `exit status: 1`, `signal: 9 (SIGKILL)`.
  package var description: String {
    switch self {
    case .exited(let code): "exit status: \(code)"
    case .signaled(let signal):
      "signal: \(signal) (\(signalName(signal)))"
    }
  }

  package var succeeded: Bool { self == .exited(0) }
}

/// `SIGKILL` for 9, as Rust prints it; `signal: N` names only.
func signalName(_ signal: Int32) -> String {
  let names = [
    1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 7: "SIGEMT",
    8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV", 12: "SIGSYS", 13: "SIGPIPE",
    14: "SIGALRM", 15: "SIGTERM", 16: "SIGURG", 17: "SIGSTOP", 18: "SIGTSTP", 19: "SIGCONT",
    20: "SIGCHLD", 21: "SIGTTIN", 22: "SIGTTOU", 23: "SIGIO", 24: "SIGXCPU", 25: "SIGXFSZ",
    26: "SIGVTALRM", 27: "SIGPROF", 28: "SIGWINCH", 29: "SIGINFO", 30: "SIGUSR1", 31: "SIGUSR2",
  ]
  return names[Int(signal)] ?? "unknown signal"
}
