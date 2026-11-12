import Foundation
import IsoCore

/// The boots whose computer-use counts an instance's audit already holds
/// (`computer-use-audited.json`). A boot's counts reach the host twice: from
/// its running owner when `iso stop` stops it, and afterwards from the
/// owner's log of ended boots (`endedBoots` in `inspect`), which is how a
/// boot the host did not stop is audited at all. Host-owned control state.
package enum ComputerUseAudit {
  /// More than the runtime's log holds, so a boot still listed there is
  /// still known here.
  static let limit = 32

  static func path(_ instance: Instance) -> String {
    instance.directory + "/computer-use-audited.json"
  }

  struct Record: Codable {
    var schema = 1
    var boots: [String]
  }

  /// Records `events` for `boot` unless that boot was recorded before.
  /// Best effort, as every audit write: when the record of audited boots
  /// cannot be read, nothing is recorded now and a later observation of the
  /// boot's ended counts tries again. An unparseable record counts as empty.
  package static func record(
    _ instance: Instance, boot: String, _ events: [BoundaryAudit.Event],
    diagnostics: Diagnostics? = nil
  ) {
    guard !events.isEmpty else { return }
    let path = path(instance)
    do {
      let lock = try FileLock.sibling(of: path)
      defer { lock.release() }
      var boots =
        try StateStore.readControlFile(path).flatMap {
          try? StateStore.decode(Record.self, $0, path: path)
        }?.boots ?? []
      guard !boots.contains(boot) else { return }
      for event in events { BoundaryAudit.record(instance, event, diagnostics: diagnostics) }
      boots.append(boot)
      try StateStore.writeControlFile(Record(boots: Array(boots.suffix(limit))), to: path)
    } catch {
      diagnostics?.debug("computer-use audit for boot \(boot) not recorded (non-fatal): \(error)")
    }
  }
}
