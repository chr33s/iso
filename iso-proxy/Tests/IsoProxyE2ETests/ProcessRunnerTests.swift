import Darwin
import Foundation
import IsoProxyTestSupport
import Testing

@Test func childDeadlineAndCleanupRemainBounded() async throws {
  let evidence = try Evidence("process-deadline")
  let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
  defer { try? input.close() }
  let child = try TestProcessRunner(
    executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
    input: input.fileDescriptor, evidence: evidence, name: "sleep")
  defer { child.cleanup() }
  let started = ContinuousClock.now
  do {
    _ = try await child.wait(seconds: 0)
    Issue.record("child exceeded deadline without failing")
  } catch ObservationFailure.invalid {
    #expect(started.duration(to: .now) < .seconds(1))
  }
  child.cleanup()
  #expect(
    started.duration(to: .now) < .seconds(1),
    "cleanup must kill and reap without waiting for the workload")
  #expect(try child.poll() != nil)
  #expect(kill(child.pid, 0) == -1 && errno == ESRCH)
  // Cleanup is idempotent after reaping.
  child.cleanup()
}
