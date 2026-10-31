import Containerization

/// The guest process operations whose lifetime is owned by one exec request.
protocol GuestProcess: Sendable {
  func start() async throws
  func wait(timeoutInSeconds: Int64?) async throws -> ExitStatus
  func kill(_ signal: Signal) async throws
  func delete() async throws
}

extension LinuxProcess: GuestProcess {}

/// How long an `exec` waits for its guest process. Every exec is bounded:
/// a request without a timeout gets `defaultSeconds`, and none may ask for
/// more than `maxSeconds`, so no request holds a control connection (and
/// the owner's task for it) forever.
package struct ExecTimeout: Sendable, Equatable {
  package static let defaultSeconds: Int64 = 600
  package static let maxSeconds: Int64 = 86_400
  package static let `default` = ExecTimeout(checked: defaultSeconds)

  package let seconds: Int64

  private init(checked seconds: Int64) { self.seconds = seconds }

  /// `requested` nil is the default; anything outside 1...`maxSeconds` is
  /// refused rather than clamped, so a caller never gets a different bound
  /// than it asked for.
  package init(requested: Int64?) throws(SandboxError) {
    guard let requested else {
      self = .default
      return
    }
    guard (1...Self.maxSeconds).contains(requested) else {
      throw SandboxError("exec timeout must be 1...\(Self.maxSeconds) seconds; got \(requested)")
    }
    seconds = requested
  }
}

func runGuestProcess(_ process: some GuestProcess, timeout: ExecTimeout) async throws -> ExitStatus
{
  var exited = false
  defer {
    // Teardown must reach the guest even when this exec request was cancelled.
    await withTaskCancellationShield {
      if !exited { try? await process.kill(.kill) }
      try? await process.delete()
    }
  }
  try await process.start()
  let status = try await process.wait(timeoutInSeconds: timeout.seconds)
  exited = true
  return status
}
