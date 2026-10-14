import Foundation
import IsoCore
import Testing

@testable import IsoHost

/// A readiness `ssh` that hangs `hangs` times before succeeding; `-O exit`
/// (closing the master) always succeeds.
private func hangingSSH(_ guest: FakeGuest, hangs: Int) throws {
  try writeFile(
    guest.root + "/bin/ssh",
    """
    #!/bin/sh
    case "$*" in *'-O exit'*) exit 0 ;; esac
    count="$(cat '\(guest.root)/attempts' 2>/dev/null || echo 0)"
    echo $((count + 1)) > '\(guest.root)/attempts'
    [ "$count" -lt \(hangs) ] && exec sleep 30
    exit 0
    """, mode: 0o755)
}

@Test func aHeldBackReadinessAttemptIsCutOffAndRetried() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  try hangingSSH(guest, hangs: 1)
  // The per-attempt deadline is generous enough that only the hung attempt
  // ever reaches it, even on a loaded machine; the overall timeout is larger
  // still, so success needs the cut-off.
  try guest.client.waitUntilReady(
    guest.target, timeout: .seconds(12), diagnostics: guest.sink.diagnostics,
    attemptDeadline: .seconds(3))
  #expect(
    readFile(guest.root + "/attempts")?.trimmingCharacters(in: .whitespacesAndNewlines) == "2")
  #expect(guest.sink.text.contains("SSH is ready"))
}

@Test func readinessThatNeverConnectsNamesLocalNetworkPrivacy() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  try hangingSSH(guest, hangs: .max)
  let error = #expect(throws: HostError.self) {
    try guest.client.waitUntilReady(
      guest.target, timeout: .seconds(1), diagnostics: guest.sink.diagnostics,
      attemptDeadline: .milliseconds(300))
  }
  #expect(error?.description.contains("no connection attempt completed") == true)
  #expect(error?.description.contains("Local Network") == true)
}

@Test func readinessThatIsRefusedKeepsTheSSHDMessage() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  try writeFile(
    guest.root + "/bin/ssh", "#!/bin/sh\necho 'guest-chosen disconnect text' >&2\nexit 255\n",
    mode: 0o755)
  let error = #expect(throws: HostError.self) {
    try guest.client.waitUntilReady(
      guest.target, timeout: .milliseconds(300), diagnostics: guest.sink.diagnostics,
      attemptDeadline: .seconds(5))
  }
  #expect(error?.description.contains("sshd may not be running") == true)
  // ssh's own output is guest-influenced and never reaches the error.
  #expect(error?.description.contains("guest-chosen") == false)
}
