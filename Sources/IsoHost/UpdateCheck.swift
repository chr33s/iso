import Foundation
import IsoConfiguration
import IsoCore

/// Background update-check state (`update-check.json`).
public struct UpdateState: Sendable, Equatable {
  public var lastCheckedAt: UInt64
  public var latestKnownVersion: String?

  public init(lastCheckedAt: UInt64 = 0, latestKnownVersion: String? = nil) {
    self.lastCheckedAt = lastCheckedAt
    self.latestKnownVersion = latestKnownVersion
  }

  /// `serde_json::to_string_pretty` of the Rust struct (no trailing newline).
  var rendered: String {
    var text = OutputJSON.object([
      ("last_checked_at", .uint(lastCheckedAt)),
      ("latest_known_version", .optional(latestKnownVersion)),
    ]).rendered()
    text.removeLast()
    return text
  }

  /// Both fields default when absent (serde `default`); anything
  /// malformed, including a null count, is no state.
  static func parse(_ bytes: [UInt8]) -> UpdateState? {
    try? JSONDecoder().decode(Stored.self, from: Data(bytes)).state
  }

  private struct Stored: Decodable {
    let state: UpdateState

    enum CodingKeys: String, CodingKey {
      case lastCheckedAt = "last_checked_at"
      case latestKnownVersion = "latest_known_version"
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let checked =
        container.contains(.lastCheckedAt)
        ? try container.decode(UInt64.self, forKey: .lastCheckedAt) : 0
      let tag = try container.decodeIfPresent(String.self, forKey: .latestKnownVersion)
      state = UpdateState(lastCheckedAt: checked, latestKnownVersion: tag)
    }
  }
}

/// The background update check and the startup notice. Every path is
/// best-effort and silent on failure; nothing here ever installs anything.
public enum UpdateCheck {
  /// `dirs::data_local_dir()/iso/update-check.json` on macOS.
  public static func statePath(home: String?) -> String? {
    guard let home, !home.isEmpty else { return nil }
    return home + "/Library/Application Support/iso/update-check.json"
  }

  public static let nowUnix: @Sendable () -> UInt64 = {
    UInt64(max(0, Date().timeIntervalSince1970.rounded(.down)))
  }

  /// Remove the state file, and its directory when that leaves it empty.
  /// Used by `iso uninstall`.
  public static func removeState(home: String?, diagnostics: Diagnostics) throws {
    guard let path = statePath(home: home) else { return }
    if pathExists(path), unlink(path) != 0 {
      throw ContextError("Failed to remove \(path)", cause: HostError(rustIOError(errno)))
    }
    let parent = (path as NSString).deletingLastPathComponent
    if pathExists(parent), rmdir(parent) != 0 {
      diagnostics.debug("Leaving state dir \(parent) in place (\(rustIOError(errno)))")
    }
  }

  public static func readState(home: String?) -> UpdateState? {
    guard let path = statePath(home: home), let bytes = try? readBytes(path),
      String(validating: bytes, as: UTF8.self) != nil
    else { return nil }
    return UpdateState.parse(bytes)
  }

  static func writeState(_ state: UpdateState, home: String?) throws {
    guard let path = statePath(home: home) else {
      throw HostError("Cannot determine state directory")
    }
    try ReplaceFile.write(Array(state.rendered.utf8), to: path, newFileMode: 0o644)
  }

  /// Best-effort: an unwritable state directory just means the next run
  /// checks again.
  static func persist(tag: String?, home: String?, now: UInt64, diagnostics: Diagnostics) {
    do {
      try writeState(UpdateState(lastCheckedAt: now, latestKnownVersion: tag), home: home)
    } catch {
      diagnostics.debug("Failed to persist update-check state: \(error)")
    }
  }

  /// Dev builds, `ISO_NO_UPDATE_CHECK=1`, `CI=true` and a non-terminal
  /// stdin all disable the check and the notice.
  static func disabled(build: IsoBuild, environment: [String: String], stdinIsTerminal: Bool)
    -> Bool
  {
    build.kind == .dev || environment["ISO_NO_UPDATE_CHECK"] == "1"
      || environment["CI"] == "true" || !stdinIsTerminal
  }

  static func notifyIsDue(current: SemanticVersion, latest: SemanticVersion) -> Bool {
    latest > current
  }

  static func intervalElapsed(now: UInt64, lastCheckedAt: UInt64, intervalHours: UInt64) -> Bool {
    let (seconds, overflow) = intervalHours.multipliedReportingOverflow(by: 3600)
    let interval = overflow ? UInt64.max : seconds
    let elapsed = now >= lastCheckedAt ? now - lastCheckedAt : 0
    return elapsed >= interval
  }

  /// Startup notice on stderr when the last successful check saw a newer
  /// release. Silent otherwise.
  public static func maybePrintNotify(
    _ config: UpdateConfig, updater: Updater, stdinIsTerminal: Bool
  ) {
    guard config.mode != .off,
      !disabled(
        build: updater.build, environment: updater.environment, stdinIsTerminal: stdinIsTerminal),
      let current = try? SemanticVersion(parsing: updater.build.version),
      let tag = readState(home: updater.home)?.latestKnownVersion,
      let latest = try? SemanticVersion(parsing: UpdateChannel.stripV(tag))
    else { return }
    if notifyIsDue(current: current, latest: latest) {
      updater.diagnostics.warn(
        "A newer iso (\(latest)) is available. Run `iso update` to install it.")
    }
  }

  /// Refresh release metadata on a detached thread when the interval has
  /// elapsed. The timestamp is written before the thread starts so short
  /// commands, which exit before the request finishes, do not re-trigger
  /// the check on every run. Returns whether a refresh was started.
  @discardableResult
  public static func maybeRunBackgroundCheck(
    _ config: UpdateConfig, updater: Updater, stdinIsTerminal: Bool,
    spawn: (@escaping @Sendable () -> Void) -> Void = { body in Thread.detachNewThread(body) }
  ) -> Bool {
    guard config.mode != .off,
      !disabled(
        build: updater.build, environment: updater.environment, stdinIsTerminal: stdinIsTerminal)
    else { return false }
    let state = readState(home: updater.home) ?? UpdateState()
    guard
      intervalElapsed(
        now: updater.now(), lastCheckedAt: state.lastCheckedAt,
        intervalHours: config.checkIntervalHours)
    else { return false }
    persist(
      tag: state.latestKnownVersion, home: updater.home, now: updater.now(),
      diagnostics: updater.diagnostics)
    spawn {
      do {
        let release = try updater.fetchLatest()
        persist(
          tag: release.tag, home: updater.home, now: updater.now(), diagnostics: updater.diagnostics
        )
      } catch {
        updater.diagnostics.debug("background update-check failed: \(error)")
      }
    }
    return true
  }
}

/// Atomic replacement whose mode follows an existing file through symlinks
/// (Rust `atomic_write_json` / `atomic_write_ssh` use `fs::metadata`); a new
/// file gets `newFileMode`. A symlink at `path` is replaced, not followed.
enum ReplaceFile {
  static func write(_ bytes: [UInt8], to path: String, newFileMode: mode_t) throws(HostError) {
    let parent = (path as NSString).deletingLastPathComponent
    if !parent.isEmpty {
      do {
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
      } catch {
        throw HostError("Failed to create directory \(parent)")
      }
    }
    var existing = stat()
    let mode = stat(path, &existing) == 0 ? existing.st_mode & 0o7777 : newFileMode
    let temporary = AtomicFile.temporaryPath(for: path)
    let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw .posix("Failed to write temp file", temporary) }
    var published = false
    defer { if !published { unlink(temporary) } }
    do {
      defer { close(fd) }
      var offset = 0
      while offset < bytes.count {
        let written = bytes[offset...].withUnsafeBytes {
          Darwin.write(fd, $0.baseAddress, $0.count)
        }
        if written < 0 {
          if errno == EINTR { continue }
          throw HostError.posix("Failed to write temp file", temporary)
        }
        offset += written
      }
      guard fchmod(fd, mode) == 0 else {
        throw HostError.posix("Failed to set permissions on", temporary)
      }
      guard fsync(fd) == 0 else { throw HostError.posix("Failed to sync", temporary) }
    }
    guard rename(temporary, path) == 0 else {
      throw .posix("Failed to rename \(temporary) ->", path)
    }
    published = true
  }
}
