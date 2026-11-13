import Foundation

/// One boot's computer-use counts as its owner last wrote them: what `inspect`
/// reports as `runtime` while the boot runs, kept after it so the host can audit
/// a boot it did not stop (session expiry, guest poweroff, an owner crash).
/// Counts only: no pixels, coordinates, text or token.
package struct BootCounts: Codable, Equatable, Sendable {
  package var bootId: String
  package var guestComputerUse: MacGuestCUCounters?
  package var liveView: MacLiveViewCounters?

  package init(bootId: String, _ counts: DesktopStatus) {
    self.bootId = bootId
    guestComputerUse = counts.guestComputerUse
    liveView = counts.liveView
  }
}

/// A sandbox's `boot-counts.json`: its most recent boots that had counts, oldest
/// first.
/// More than one, because launchd restarts a crashed owner before the host reads the crashed boot's
/// counts.
package enum BootCountsLog {
  package static let limit = 8
  /// How often a running owner writes changed counts: what a crash loses.
  package static let interval: Duration = .seconds(30)

  /// An unreadable file holds no boots; the next write replaces it.
  static func load(_ url: URL) -> [BootCounts] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    return (try? JSONDecoder.iso.decode([BootCounts].self, from: data)) ?? []
  }

  /// Of `recorded`, the boots that have ended: all but `live`, the boot an owner
  /// is running now. Nil when there is none.
  /// `recorded` must be loaded before `live` is read: an owner writes live.json before its counts,
  /// so a boot loaded first is `live` or ended.
  package static func ended(_ recorded: [BootCounts], live: String?) -> [BootCounts]? {
    let boots = recorded.filter { $0.bootId != live }.suffix(limit)
    return boots.isEmpty ? nil : Array(boots)
  }
}

/// Writes one boot's counts into its sandbox's log.
/// One owner runs at a time (the owner lock); reading and writing counts stay on the main actor, so
/// a later write never carries earlier counts.
@MainActor
package final class BootCountsRecorder {
  private let url: URL
  private let bootId: String
  private let log: @Sendable (String) -> Void
  /// This boot's counts now. Set once the display exists; nothing is
  /// written before.
  package var counts: (@MainActor () -> DesktopStatus)?
  private var written: DesktopStatus?

  package nonisolated init(
    url: URL, bootId: String, log: @escaping @Sendable (String) -> Void,
    counts: (@MainActor () -> DesktopStatus)? = nil
  ) {
    self.url = url
    self.bootId = bootId
    self.log = log
    self.counts = counts
  }

  /// Writes the counts if they changed since the last write. A boot with
  /// none (no guest computer use, no stream started) writes nothing.
  package func record() {
    guard let now = counts?(), now.guestComputerUse != nil || now.liveView != nil,
      now != written
    else { return }
    var boots = BootCountsLog.load(url).filter { $0.bootId != bootId }
    boots.append(BootCounts(bootId: bootId, now))
    do {
      try JSONEncoder.pretty.encode(Array(boots.suffix(BootCountsLog.limit)))
        .write(to: url, options: .atomic)
      written = now
    } catch {
      log("boot counts not written: \(error)")
    }
  }

  /// Records now and then every ``BootCountsLog/interval``, for the
  /// owner's life.
  package func recordPeriodically() {
    Task { @MainActor in
      while true {
        record()
        try? await Task.sleep(for: BootCountsLog.interval)
      }
    }
  }
}
