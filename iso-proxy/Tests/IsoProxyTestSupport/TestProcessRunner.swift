import Darwin
import Foundation

/// Test-only launcher: explicit argv/environment, private process group, file-backed output,
/// wall-clock deadlines and unconditional cleanup. No shell or inherited credentials.
public final class TestProcessRunner {
  public let pid: pid_t
  public let stdout: URL
  public let stderr: URL
  private var status: Int32?
  private var cleaned = false

  public init(
    executable: URL, arguments: [String] = [], environment: [String: String] = [:],
    input: Int32, evidence: Evidence, name: String
  ) throws {
    try JSONSerialization.data(
      withJSONObject: [
        "executable": executable.path, "arguments": arguments,
        "environment_keys": environment.keys.sorted(),
      ], options: [.sortedKeys, .prettyPrinted]
    )
    .write(to: evidence.file("\(name).launch.json"), options: .atomic)
    stdout = evidence.file("\(name).stdout")
    stderr = evidence.file("\(name).stderr")
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    try check(posix_spawn_file_actions_init(&actions) == 0, "spawn file actions")
    defer { posix_spawn_file_actions_destroy(&actions) }
    try check(posix_spawnattr_init(&attributes) == 0, "spawn attributes")
    defer { posix_spawnattr_destroy(&attributes) }
    try check(
      posix_spawnattr_setflags(
        &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0, "spawn flags"
    )
    try check(posix_spawnattr_setpgroup(&attributes, 0) == 0, "spawn process group")
    try check(posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO) == 0, "spawn stdin")
    for (fd, path) in [(STDOUT_FILENO, stdout.path), (STDERR_FILENO, stderr.path)] {
      try check(
        posix_spawn_file_actions_addopen(&actions, fd, path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
          == 0, "spawn output")
    }
    let argv = ([executable.path] + arguments).map { strdup($0) }
    let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
    defer { for pointer in argv + envp { free(pointer) } }
    try check((argv + envp).allSatisfy { $0 != nil }, "spawn argument allocation")
    var child: pid_t = 0
    let result = (argv + [nil]).withUnsafeBufferPointer { arguments in
      (envp + [nil]).withUnsafeBufferPointer { environment in
        // Both arrays contain at least the nil terminator, so baseAddress is present.
        posix_spawn(
          &child, executable.path, &actions, &attributes,
          UnsafeMutablePointer(mutating: arguments.baseAddress!),
          UnsafeMutablePointer(mutating: environment.baseAddress!))
      }
    }
    try check(result == 0, "spawn failed: \(result)")
    pid = child
  }

  public func poll() throws -> Int32? {
    if let status { return status }
    var raw: Int32 = 0
    let result = waitpid(pid, &raw, WNOHANG)
    if result == 0 { return nil }
    if result < 0 && errno == EINTR { return nil }
    try check(result == pid, "waitpid failed")
    status = Self.exitStatus(raw)
    return status
  }

  public func wait(seconds: Int = 5) async throws -> Int32 {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
      try checkOutputSize()
      if let status = try poll() { return status }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw ObservationFailure.invalid("child deadline exceeded; diagnostics: \(stderr.path)")
  }

  private static func exitStatus(_ raw: Int32) -> Int32 {
    // wait(2) macros are not imported into Swift.
    raw & 0x7f == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
  }
  public func terminate() { if !cleaned { _ = kill(-pid, SIGTERM) } }
  public func cleanup() {
    guard !cleaned else { return }
    cleaned = true
    // Kill descendants even if the leader has already exited; reap only our own child.
    _ = kill(-pid, SIGKILL)
    if status == nil {
      var raw: Int32 = 0
      while waitpid(pid, &raw, 0) < 0 && errno == EINTR {}
      status = Self.exitStatus(raw)
    }
  }
  private func checkOutputSize() throws {
    let out = try stdout.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    let err = try stderr.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    try check(
      out <= 4 * 1024 * 1024 && err <= 4 * 1024 * 1024 && out + err <= 4 * 1024 * 1024,
      "unbounded child diagnostics")
  }
  public func output() throws -> Data {
    try checkOutputSize()
    let out = try Data(contentsOf: stdout)
    let err = try Data(contentsOf: stderr)
    try check(out.count + err.count <= 4 * 1024 * 1024, "unbounded child diagnostics")
    return out + err
  }
}

public func inputFile(_ data: Data, evidence: Evidence, name: String) throws -> FileHandle {
  let path = evidence.file("\(name).input")
  try data.write(to: path)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
  return try FileHandle(forReadingFrom: path)
}

public func proxyBinary() throws -> URL {
  if let path = ProcessInfo.processInfo.environment["ISO_PROXY_E2E_BINARY"] {
    try check(path.hasPrefix("/"), "ISO_PROXY_E2E_BINARY must be absolute")
    let binary = try canonicalExecutable(URL(fileURLWithPath: path))
    try check(
      FileManager.default.isExecutableFile(atPath: binary.path), "proxy binary is not executable")
    return binary
  }
  // SwiftPM's pinned toolchain builds executable products before running tests.
  // Resolve beside the active .xctest bundle, including custom scratch/configuration paths.
  let binary = try activeTestBundle().deletingLastPathComponent().appendingPathComponent(
    "iso-proxy")
  try check(
    FileManager.default.isExecutableFile(atPath: binary.path),
    "build iso-proxy or set ISO_PROXY_E2E_BINARY")
  return try canonicalExecutable(binary)
}

private func canonicalExecutable(_ url: URL) throws -> URL {
  // Foundation preserves /var aliases on macOS; Seatbelt matches /private/var.
  guard let path = realpath(url.path, nil) else {
    throw ObservationFailure.invalid("cannot resolve proxy executable")
  }
  defer { free(path) }
  return URL(fileURLWithPath: String(cString: path))
}

public func activeTestBundle() throws -> URL {
  var info = Dl_info()
  try check(dladdr(#dsohandle, &info) != 0, "test image lookup failed")
  guard let name = info.dli_fname else {
    throw ObservationFailure.invalid("test image path missing")
  }
  var image = URL(fileURLWithPath: String(cString: name)).resolvingSymlinksInPath()
  while image.path != "/" {
    if image.pathExtension == "xctest" { return image }
    image.deleteLastPathComponent()
  }
  throw ObservationFailure.invalid("set ISO_PROXY_E2E_BINARY to the production executable")
}
