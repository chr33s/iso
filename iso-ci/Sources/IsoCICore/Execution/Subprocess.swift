import Darwin
import Foundation

/// Every subprocess iso-ci starts goes through here: an absolute executable,
/// an explicit argv (never a shell string), an explicit environment, only
/// the listed descriptors inherited (POSIX_SPAWN_CLOEXEC_DEFAULT), bounded
/// output, and a deadline after which the process group is killed.
package enum Subprocess {
  package struct Output: Sendable, Equatable {
    package let status: Int32
    package let stdout: [UInt8]
    package let stderr: [UInt8]
    package let timedOut: Bool
    /// True when stdout or stderr exceeded its limit and was truncated.
    package let truncated: Bool

    package var succeeded: Bool { status == 0 && !timedOut }
  }

  package struct Request: Sendable {
    package var executable: String
    package var arguments: [String]
    package var environment: [String: String]
    package var input: [UInt8]
    package var timeout: Duration
    package var outputLimit: Int
    package var workingDirectory: String?

    package init(
      executable: String, arguments: [String], environment: [String: String] = [:],
      input: [UInt8] = [], timeout: Duration = .seconds(60), outputLimit: Int = 1 << 20,
      workingDirectory: String? = nil
    ) {
      self.executable = executable
      self.arguments = arguments
      self.environment = environment
      self.input = input
      self.timeout = timeout
      self.outputLimit = outputLimit
      self.workingDirectory = workingDirectory
    }
  }

  /// A minimal environment for tools: PATH, HOME, LANG; nothing secret.
  package static func baseEnvironment(
    _ source: [String: String] = ProcessInfo.processInfo.environment
  )
    -> [String: String]
  {
    var out = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin", "LANG": "C",
    ]
    if let home = source["HOME"] { out["HOME"] = home }
    if let user = source["USER"] { out["USER"] = user }
    if let tmp = source["TMPDIR"] { out["TMPDIR"] = tmp }
    return out
  }

  /// The base environment plus the operator's SSH agent socket, for the
  /// iso processes that open a remote host's pinned SSH connection (an
  /// enrolled host's key may be usable only through the agent). iso keeps it
  /// only for that connection and never forwards the agent; guest sessions
  /// set `IdentityAgent none`. Only an absolute socket path is passed.
  package static func hostConnectionEnvironment(
    _ source: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    var out = baseEnvironment(source)
    if let socket = source["SSH_AUTH_SOCK"], socket.hasPrefix("/"),
      !socket.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
    {
      out["SSH_AUTH_SOCK"] = socket
    }
    return out
  }

  /// Runs to completion (or the deadline) and captures bounded output.
  package static func run(_ request: Request) throws(CIError) -> Output {
    guard request.executable.hasPrefix("/") else {
      throw CIError.invalid("subprocess executable must be an absolute path")
    }
    var stdinPipe: [Int32] = [-1, -1]
    var stdoutPipe: [Int32] = [-1, -1]
    var stderrPipe: [Int32] = [-1, -1]
    guard pipe(&stdinPipe) == 0, pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
      for fd in stdinPipe + stdoutPipe + stderrPipe where fd >= 0 { close(fd) }
      throw CIError(.internalError, "cannot create pipes")
    }
    let pid: pid_t
    do {
      pid = try spawn(
        request.executable, request.arguments, request.environment,
        stdin: stdinPipe[0], stdout: stdoutPipe[1], stderr: stderrPipe[1],
        workingDirectory: request.workingDirectory)
    } catch {
      for fd in stdinPipe + stdoutPipe + stderrPipe { close(fd) }
      throw error
    }
    close(stdinPipe[0])
    close(stdoutPipe[1])
    close(stderrPipe[1])
    let inputFD = stdinPipe[1]
    _ = fcntl(inputFD, F_SETNOSIGPIPE, 1)
    let input = request.input
    let writer = Thread {
      writeAll(inputFD, input)
      close(inputFD)
    }
    writer.start()

    let collector = OutputCollector(limit: request.outputLimit)
    let group = DispatchGroup()
    for (fd, isOut) in [(stdoutPipe[0], true), (stderrPipe[0], false)] {
      group.enter()
      Thread.detachNewThread {
        collector.drain(fd, isStdout: isOut)
        close(fd)
        group.leave()
      }
    }
    let deadline =
      DispatchTime.now() + .nanoseconds(Int(request.timeout.components.seconds) * 1_000_000_000)
    // EOF may never arrive: a descendant outside the process group (an ssh
    // ProxyCommand) can hold the pipes open, so reading stops after a grace.
    var timedOut = false
    var reaped = false
    var status: Int32 = 0
    var graceUntil: DispatchTime?
    while group.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
      let now = DispatchTime.now()
      if !reaped, waitpid(pid, &status, WNOHANG) == pid {
        reaped = true
        graceUntil = graceUntil ?? now + Self.drainGrace
      }
      if graceUntil == nil, now >= deadline {
        timedOut = true
        kill(-pid, SIGKILL)
        kill(pid, SIGKILL)
        graceUntil = now + Self.drainGrace
      }
      if let graceUntil, now >= graceUntil {
        collector.abandon()
        group.wait()
        break
      }
    }
    if !reaped { while waitpid(pid, &status, 0) < 0 && errno == EINTR {} }
    let exit: Int32 =
      (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    let captured = collector.result()
    return Output(
      status: exit, stdout: captured.stdout, stderr: captured.stderr, timedOut: timedOut,
      truncated: captured.truncated)
  }

  /// How long output is still read after the child exits or is killed.
  static let drainGrace: DispatchTimeInterval = .seconds(2)

  /// Spawns with exactly the given stdio descriptors inherited, in its own
  /// process group. The caller owns and must reap the returned pid.
  package static func spawn(
    _ executable: String, _ arguments: [String], _ environment: [String: String],
    stdin: Int32, stdout: Int32, stderr: Int32, workingDirectory: String? = nil
  ) throws(CIError) -> pid_t {
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
    }
    posix_spawn_file_actions_adddup2(&actions, stdin, 0)
    posix_spawn_file_actions_adddup2(&actions, stdout, 1)
    posix_spawn_file_actions_adddup2(&actions, stderr, 2)
    if let workingDirectory {
      posix_spawn_file_actions_addchdir(&actions, workingDirectory)
    }
    posix_spawnattr_setflags(
      &attributes,
      Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF))
    posix_spawnattr_setpgroup(&attributes, 0)
    var defaults = sigset_t()
    sigemptyset(&defaults)
    sigaddset(&defaults, SIGPIPE)
    posix_spawnattr_setsigdefault(&attributes, &defaults)

    let argv = [executable] + arguments
    let env = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    var pid: pid_t = 0
    let result = withCStrings(argv) { argvPointers in
      withCStrings(env) { envPointers in
        posix_spawn(&pid, executable, &actions, &attributes, argvPointers, envPointers)
      }
    }
    guard result == 0 else {
      throw CIError(
        .internalError,
        "cannot start \((executable as NSString).lastPathComponent) (\(String(cString: strerror(result))))"
      )
    }
    return pid
  }

  /// Resolves a tool on a fixed search path (never the caller's PATH).
  package static func which(_ name: String, extraDirectories: [String] = []) -> String? {
    for directory in extraDirectories + [
      "/usr/bin", "/bin", "/usr/sbin", "/opt/homebrew/bin", "/usr/local/bin",
    ] {
      let path = directory + "/" + name
      if access(path, X_OK) == 0 { return path }
    }
    return nil
  }
}

private func withCStrings<R>(
  _ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R
) -> R {
  var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
  pointers.append(nil)
  defer { for pointer in pointers { free(pointer) } }
  return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}

private final class OutputCollector: @unchecked Sendable {
  private let lock = NSLock()
  private let limit: Int
  private var stdout: [UInt8] = []
  private var stderr: [UInt8] = []
  private var truncated = false
  private var abandoned = false

  init(limit: Int) { self.limit = limit }

  /// Stops every drain within one poll interval, EOF or not.
  func abandon() {
    lock.lock()
    abandoned = true
    lock.unlock()
  }

  private var isAbandoned: Bool {
    lock.lock()
    defer { lock.unlock() }
    return abandoned
  }

  func drain(_ fd: Int32, isStdout: Bool) {
    var buffer = [UInt8](repeating: 0, count: 16 << 10)
    while !isAbandoned {
      var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let ready = poll(&descriptor, 1, 100)
      if ready < 0 {
        if errno == EINTR { continue }
        return
      }
      if ready == 0 { continue }
      let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR { continue }
        return
      }
      if count == 0 { return }
      lock.lock()
      if isStdout {
        let room = max(0, limit - stdout.count)
        stdout += buffer[0..<min(count, room)]
        if count > room { truncated = true }
      } else {
        let room = max(0, limit - stderr.count)
        stderr += buffer[0..<min(count, room)]
        if count > room { truncated = true }
      }
      lock.unlock()
    }
  }

  func result() -> (stdout: [UInt8], stderr: [UInt8], truncated: Bool) {
    lock.lock()
    defer { lock.unlock() }
    return (stdout, stderr, truncated)
  }
}
