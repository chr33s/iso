// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoConfiguration
import IsoCore

/// A child that outlives the call: its own process group (so Ctrl-C to
/// iso does not reach it), stdout to `/dev/null`, stderr to a log. It is
/// reaped by `poll` once it exits, or killed and reaped by `kill`.
struct DetachedChild {
  enum Input { case null, pipe }

  let pid: pid_t
  private var stdinWriter: Int32
  private var reaped = false

  static func spawn(
    executable: String, arguments: [String], environment: [String: String], stdin: Input,
    stderr: Int32, inherit: [(Int32, Int32)] = [], workingDirectory: String? = nil
  ) throws -> DetachedChild {
    var pipeFDs: [Int32] = [-1, -1]
    if stdin == .pipe {
      guard pipe(&pipeFDs) == 0 else {
        throw HostError.posix("Failed to create pipe for", executable)
      }
      _ = fcntl(pipeFDs[1], F_SETFD, FD_CLOEXEC)
      _ = fcntl(pipeFDs[1], F_SETNOSIGPIPE, 1)
    }
    defer { if pipeFDs[0] >= 0 { close(pipeFDs[0]) } }
    var actions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    if stdin == .pipe {
      posix_spawn_file_actions_adddup2(&actions, pipeFDs[0], 0)
    } else {
      posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    }
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, stderr, 2)
    for (source, target) in inherit {
      posix_spawn_file_actions_adddup2(&actions, source, target)
    }
    if let workingDirectory {
      posix_spawn_file_actions_addchdir(&actions, workingDirectory)
    }
    var attributes: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setpgroup(&attributes, 0)
    var signals = sigset_t()
    sigemptyset(&signals)
    posix_spawnattr_setsigmask(&attributes, &signals)
    sigfillset(&signals)
    posix_spawnattr_setsigdefault(&attributes, &signals)
    posix_spawnattr_setflags(
      &attributes,
      Int16(
        POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK
          | POSIX_SPAWN_SETSIGDEF))
    let argv = [executable] + arguments
    let env = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    var pid: pid_t = 0
    let result = withCStrings(argv) { argvPointer in
      withCStrings(env) { envPointer in
        posix_spawn(&pid, executable, &actions, &attributes, argvPointer, envPointer)
      }
    }
    guard result == 0 else {
      if pipeFDs[1] >= 0 { close(pipeFDs[1]) }
      throw HostError("Failed to spawn \(executable): \(String(cString: strerror(result)))")
    }
    return DetachedChild(pid: pid, stdinWriter: pipeFDs[1])
  }

  private init(pid: pid_t, stdinWriter: Int32) {
    self.pid = pid
    self.stdinWriter = stdinWriter
  }

  /// Write everything, then EOF. A child that closed its stdin yields EPIPE.
  mutating func writeAndCloseStdin(_ bytes: [UInt8]) throws {
    guard stdinWriter >= 0 else { throw HostError("proxy child stdin unexpectedly missing") }
    defer {
      close(stdinWriter)
      stdinWriter = -1
    }
    var offset = 0
    while offset < bytes.count {
      let count = bytes[offset...].withUnsafeBytes { write(stdinWriter, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR { continue }
        throw ContextError(
          "Failed to write proxy startup config to stdin",
          cause: HostError(String(cString: strerror(errno))))
      }
      offset += count
    }
  }

  /// The exit status once the child has exited (and is reaped), else nil.
  mutating func poll() -> ProcessRunner.Termination? {
    guard !reaped else { return nil }
    var status: Int32 = 0
    let result = waitpid(pid, &status, WNOHANG)
    guard result == pid else { return nil }
    reaped = true
    return ChildProcess.decode(status)
  }

  /// Exited but unreaped: its pid and group stay reserved for signalling.
  func hasExited() -> Bool {
    guard !reaped else { return true }
    var info = siginfo_t()
    return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid
  }

  mutating func kill() {
    if stdinWriter >= 0 {
      close(stdinWriter)
      stdinWriter = -1
    }
    guard !reaped else { return }
    Darwin.kill(-pid, SIGKILL)
    Darwin.kill(pid, SIGKILL)
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    reaped = true
  }
}
