import Foundation
import IsoCore

/// The boots whose computer-use counts an instance's audit already holds
/// (`computer-use-audited.json`). Counts arrive from the running owner at
/// `iso stop` and later from its ended-boots log (`endedBoots` in `inspect`),
/// the only way a boot the host did not stop is audited. Host-owned state.
package enum ComputerUseAudit {
  static let limit = 32

  static func path(_ instance: Instance) -> String {
    instance.directory + "/computer-use-audited.json"
  }

  struct Record: Codable {
    var schema = 1
    var boots: [String]
  }

  /// Records `events` for `boot` unless it was recorded before. Best effort: when
  /// the audited-boots record cannot be read nothing is recorded now and a later
  /// observation retries; an unparseable record counts as empty.
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
