import Containerization

/// The guest process operations whose lifetime is owned by one exec request.
protocol GuestProcess: Sendable {
  func start() async throws
  func wait(timeoutInSeconds: Int64?) async throws -> ExitStatus
  func kill(_ signal: Signal) async throws
  func delete() async throws
}

extension LinuxProcess: GuestProcess {}

func runGuestProcess(_ process: some GuestProcess, timeout: Int64?) async throws -> ExitStatus {
  var exited = false
  defer {
    // Teardown must reach the guest even when this exec request was cancelled.
    await withTaskCancellationShield {
      if !exited { try? await process.kill(.kill) }
      try? await process.delete()
    }
  }
  try await process.start()
  let status = try await process.wait(timeoutInSeconds: timeout)
  exited = true
  return status
}
