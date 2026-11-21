import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

private struct Fixture {
  let root: String
  var tree: String { root + "/tree" }
  var destination: String { root + "/dest" }
  var outside: String { root + "/outside" }

  init() throws {
    let path = FileManager.default.temporaryDirectory
      .appending(path: "iso-stage-\(UUID().uuidString)").path
    root = canonicalPath(try Self.make(path))!
    for directory in [tree, destination, outside] { _ = try Self.make(directory) }
  }

  static func make(_ path: String) throws -> String {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  func write(_ relative: String, _ text: String, in base: String, mode: Int = 0o644) throws {
    let path = base + "/" + relative
    _ = try Self.make((path as NSString).deletingLastPathComponent)
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    chmod(path, mode_t(mode))
  }

  func link(_ relative: String, to target: String, in base: String) throws {
    let path = base + "/" + relative
    _ = try Self.make((path as NSString).deletingLastPathComponent)
    try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
  }

  func read(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
  }

  func build(_ limits: StageLimits = .defaults) throws -> StageManifest {
    var builder = try StageBuilder(tree: tree, destination: destination, limits: limits)
    return try builder.build(id: "0badf00d0badf00d", instance: "test")
  }

  func cleanup() {
    StageLocation.grantOwnerAccess(root)
    try? FileManager.default.removeItem(atPath: root)
  }
}

private func operations(_ manifest: StageManifest) -> [String: StageOperation] {
  Dictionary(uniqueKeysWithValues: manifest.changes.map { ($0.path, $0.operation) })
}

@Test func stageClassifiesChangesAndAppliesThem() throws {
  let f = try Fixture()
  defer { f.cleanup() }
  try f.write("a.txt", "old\n", in: f.destination)
  try f.write("same.txt", "same\n", in: f.destination)
  try f.write("was-file", "x", in: f.destination)
  try f.write("a.txt", "new\n", in: f.tree)
  try f.write("same.txt", "same\n", in: f.tree)
  try f.write("new/dir/b.sh", "#!/bin/sh\n", in: f.tree, mode: 0o755)
  try f.link("was-file", to: "a.txt", in: f.tree)
  try f.link("link", to: "a.txt", in: f.tree)

  let manifest = try f.build()
  #expect(manifest.applicable)
  #expect(
    operations(manifest) == [
      "a.txt": .modify, "new": .add, "new/dir": .add, "new/dir/b.sh": .add, "link": .add,
      "was-file": .typeChange,
    ])
  #expect(manifest.changes.map(\.path) == manifest.changes.map(\.path).sorted())

  let applied = try StageApplier(manifest: manifest, tree: f.tree).apply()
  #expect(applied.count == manifest.changes.count)
  #expect(try f.read(f.destination + "/a.txt") == "new\n")
  #expect(
    try FileManager.default.destinationOfSymbolicLink(atPath: f.destination + "/was-file")
      == "a.txt")
  #expect(
    try FileManager.default.destinationOfSymbolicLink(atPath: f.destination + "/link") == "a.txt")
  var info = stat()
  #expect(stat(f.destination + "/new/dir/b.sh", &info) == 0 && info.st_mode & 0o777 == 0o755)
  #expect(try f.build().changes.isEmpty)
}

@Test func escapingSymlinksMakeTheStageInapplicable() throws {
  let f = try Fixture()
  defer { f.cleanup() }
  try f.link("abs", to: "/etc/passwd", in: f.tree)
  try f.link("up", to: "../outside", in: f.tree)
  try f.link("d/up", to: "../../outside", in: f.tree)
  try f.link("d/ok", to: "../a.txt", in: f.tree)
  let manifest = try f.build()
  #expect(!manifest.applicable)
  #expect(manifest.issues.count == 3)
  #expect(manifest.issues.allSatisfy { $0.contains("outside the workspace") })
  #expect(operations(manifest)["d/ok"] == .add)
  #expect(throws: ReturnError.self) { try StageApplier(manifest: manifest, tree: f.tree).apply() }
  #expect(!FileManager.default.fileExists(atPath: f.destination + "/d"))
}

/// `/` followed by a combining mark is one `Character`, so a `Character`
/// split read `../\u{301}/../../outside` as three components climbing one
/// level; the kernel climbs three (through the guest's `\u{301}` directory).
@Test func symlinksHidingASeparatorInACombiningCharacterMakeTheStageInapplicable() throws {
  let f = try Fixture()
  defer { f.cleanup() }
  try f.write("\u{301}/keep", "x\n", in: f.tree)
  try f.link("d/up", to: "../\u{301}/../../outside", in: f.tree)
  let manifest = try f.build()
  #expect(!manifest.applicable)
  #expect(manifest.issues.contains { $0.contains("d/up") && $0.contains("outside the workspace") })
  #expect(!StageBuilder.staysInside(link: "a/l", target: "../\u{301}x"))
  #expect(!StageBuilder.staysInside(link: "a", target: "/\u{301}/../etc"))
}

/// A staged name that joins the `/` before it (a leading combining mark) or
/// after it (a parent ending in a prepended mark) is refused while walking:
/// a `Character` split would read `d/\u{301}x` as one component, and the
/// kernel would resolve it through the host's own `d` link.
@Test func stagedNamesJoiningASeparatorAreRefusedWhileWalking() throws {
  let f = try Fixture()
  defer { f.cleanup() }
  try f.link("d", to: f.outside, in: f.destination)
  try f.write("\u{301}x", "host\n", in: f.outside)
  try f.write("d/\u{301}x", "guest\n", in: f.tree)
  try f.write("p\u{600}/b", "guest\n", in: f.tree)
  let manifest = try f.build()
  #expect(!manifest.applicable)
  for path in ["d/\u{301}x", "p\u{600}/b"] {
    #expect(manifest.issues.contains { $0.hasPrefix(path + ":") && $0.contains("joins a '/'") })
    #expect(!manifest.changes.contains { $0.path == path })
  }
  try StageManifestValidator.validate(manifest)
}

@Test func linkContainmentIsLexical() {
  #expect(StageBuilder.staysInside(link: "a", target: "b"))
  #expect(StageBuilder.staysInside(link: "x/y/a", target: "../../b"))
  #expect(StageBuilder.staysInside(link: "x/a", target: "./../b"))
  #expect(!StageBuilder.staysInside(link: "x/a", target: "../../b"))
  #expect(!StageBuilder.staysInside(link: "a", target: "/b"))
  #expect(!StageBuilder.staysInside(link: "a", target: ""))
  #expect(!StageBuilder.staysInside(link: "a", target: "x/../../b"))
  // C1 controls, like C0 and DEL, never appear in an accepted target.
  #expect(!StageBuilder.staysInside(link: "a", target: "b\u{9B}c"))
  #expect(!StageBuilder.staysInside(link: "a", target: "b\u{85}"))
}

@Test func destinationLinksAreReplacedNotFollowed() throws {
  let f = try Fixture()
  defer { f.cleanup() }
  try f.write("target.txt", "outside\n", in: f.outside)
  try f.link("file", to: f.outside + "/target.txt", in: f.destination)
  try f.write("file", "guest\n", in: f.tree)

  let manifest = try f.build()
  #expect(operations(manifest) == ["file": .typeChange])
  _ = try StageApplier(manifest: manifest, tree: f.tree).apply()
  #expect(try f.read(f.outside + "/target.txt") == "outside\n")
  #expect(try f.read(f.destination + "/file") == "guest\n")
}

/// A file or link replaced by a directory would unlink the old object
/// before the directory exists; this release refuses the transition.
@Test func fileOrLinkToDirectoryIsRefusedBeforeAnyWrite() throws {
  let f = try Fixture()
  defer { f.cleanup() }
  try f.link("sub", to: f.outside, in: f.destination)
  try f.write("was-file", "x", in: f.destination)
  try f.write("sub/planted.txt", "guest\n", in: f.tree)
  try f.write("was-file/inner.txt", "i", in: f.tree)
  try f.write("ok.txt", "ok", in: f.tree)
  let manifest = try f.build()
  #expect(!manifest.applicable)
  #expect(manifest.issues.filter { $0.contains("with a directory") }.count == 2)
  #expect(throws: ReturnError.self) { try StageApplier(manifest: manifest, tree: f.tree).apply() }
  #expect(!FileManager.default.fileExists(atPath: f.destination + "/ok.txt"))
  #expect(!FileManager.default.fileExists(atPath: f.outside + "/planted.txt"))
}

@Test func specialFilesHardLinksAndBadNamesAreIssues() throws {
  let f = try Fixture()
  defer { f.cleanup() }
  #expect(mkfifo(f.tree + "/pipe", 0o644) == 0)
  try f.write("one", "x", in: f.tree)
  #expect(link(f.tree + "/one", f.tree + "/two") == 0)
  try f.write("line\nbreak", "x", in: f.tree)
  let manifest = try f.build()
  #expect(!manifest.applicable)
  #expect(manifest.issues.contains { $0.contains("pipe") && $0.contains("unsupported file type") })
  #expect(manifest.issues.filter { $0.contains("hard links") }.count == 2)
  #expect(manifest.issues.contains { $0.contains("line?break") && $0.contains("file name") })
}

@Test func namesMustBeUTF8WithoutControls() {
  #expect(StageBuilder.validName(Array("ok.txt".utf8)) == "ok.txt")
  #expect(StageBuilder.validName([0x66, 0xFF]) == nil)
  #expect(StageBuilder.validName([0x61, 0x1B]) == nil)
  #expect(StageBuilder.validName([0x61, 0x7F]) == nil)
  #expect(StageBuilder.validName([]) == nil)
  // C1 controls (U+0080-U+009F), as UTF-8: CSI and NEL.
  #expect(StageBuilder.validName([0x61, 0xC2, 0x9B]) == nil)
  #expect(StageBuilder.validName([0x61, 0xC2, 0x85]) == nil)
  #expect(StageBuilder.validName([0x61, 0xC2, 0xA0]) == "a\u{A0}")
}

@Test func budgetsAbortStaging() throws {
  let f = try Fixture()
  defer { f.cleanup() }
  try f.write("a", String(repeating: "x", count: 100), in: f.tree)
  try f.write("b", String(repeating: "x", count: 100), in: f.tree)
  let big = ByteCount(bytes: 1 << 20)!
  #expect(throws: StageBudgetExceeded.self) {
    try f.build(StageLimits(maxFiles: 1, maxBytes: big, maxFileBytes: big))
  }
  #expect(throws: StageBudgetExceeded.self) {
    try f.build(StageLimits(maxFiles: 10, maxBytes: big, maxFileBytes: ByteCount(bytes: 99)!))
  }
  #expect(throws: StageBudgetExceeded.self) {
    try f.build(StageLimits(maxFiles: 10, maxBytes: ByteCount(bytes: 150)!, maxFileBytes: big))
  }
  #expect(
    try f.build(StageLimits(maxFiles: 2, maxBytes: ByteCount(bytes: 200)!, maxFileBytes: big))
      .applicable)
}

@Test func hostDirectoryReplacedByGuestFileIsAnIssue() throws {
  let f = try Fixture()
  defer { f.cleanup() }
  try f.write("dir/keep.txt", "k", in: f.destination)
  try f.write("dir", "now a file", in: f.tree)
  let manifest = try f.build()
  #expect(!manifest.applicable)
  #expect(manifest.issues.first?.contains("host directory") == true)
}

@Test func stageTamperingAfterReviewIsRefused() throws {
  let f = try Fixture()
  defer { f.cleanup() }
  try f.write("a.txt", "first\n", in: f.tree)
  try f.write("b.txt", "reviewed\n", in: f.tree)
  let manifest = try f.build()
  try f.write("b.txt", "swapped\n", in: f.tree)
  let error = try #require(throws: StageApplyError.self) {
    try StageApplier(manifest: manifest, tree: f.tree).apply()
  }
  #expect(error.applied == ["a.txt"])
  #expect(error.failed == "b.txt")
  #expect(!FileManager.default.fileExists(atPath: f.destination + "/b.txt"))
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: f.destination)
      .allSatisfy { !$0.hasPrefix(".iso-stage-") })
}

@Test func destinationDriftSinceReviewIsRefusedBeforeWriting() throws {
  let f = try Fixture()
  defer { f.cleanup() }
  try f.write("a.txt", "host\n", in: f.destination)
  try f.write("a.txt", "guest\n", in: f.tree)
  try f.write("b.txt", "guest\n", in: f.tree)
  let manifest = try f.build()
  try f.write("a.txt", "edited meanwhile\n", in: f.destination)
  #expect(throws: ReturnError.self) { try StageApplier(manifest: manifest, tree: f.tree).apply() }
  #expect(try f.read(f.destination + "/a.txt") == "edited meanwhile\n")
  #expect(!FileManager.default.fileExists(atPath: f.destination + "/b.txt"))
}

@Test func interruptedApplyReportsWhatWasApplied() throws {
  let f = try Fixture()
  defer { f.cleanup() }
  try f.write("ro/.keep", "", in: f.destination)
  try f.write("a.txt", "a", in: f.tree)
  try f.write("ro/.keep", "", in: f.tree)
  try f.write("ro/x.txt", "x", in: f.tree)
  let manifest = try f.build()
  chmod(f.destination + "/ro", 0o500)
  defer { chmod(f.destination + "/ro", 0o700) }
  let error = try #require(throws: StageApplyError.self) {
    try StageApplier(manifest: manifest, tree: f.tree).apply()
  }
  #expect(error.applied == ["a.txt"])
  #expect(error.failed == "ro/x.txt")
  #expect(error.description.contains("Already applied (1)"))
}

@Test func stageRemovalHandlesLockedDirectories() throws {
  let f = try Fixture()
  defer { f.cleanup() }
  let location = StageLocation(root: f.root + "/returns")
  try makeSelectedStage(location, destination: f.destination) { tree in
    try f.write("locked/inner/file", "x", in: tree)
    chmod(tree + "/locked/inner", 0o000)
  }
  chmod(try location.loadSelected().stage.tree + "/locked", 0o000)
  try location.remove()
  #expect(!location.exists)
}

@Test func manifestRoundTripsThroughTheStageLocation() throws {
  let f = try Fixture()
  defer { f.cleanup() }
  let location = StageLocation(root: f.root + "/returns")
  let selected = try makeSelectedStage(location, destination: f.destination) {
    try f.write("a.txt", "x", in: $0)
  }
  #expect(try location.loadSelected().manifest == selected.manifest)
  #expect(selected.manifest.version == 2 && selected.manifest.returnPolicy == .sensitiveGrants)
  var info = stat()
  #expect(
    stat(selected.stage.manifestPath, &info) == 0 && info.st_mode & 0o777 == 0o600)
  #expect(stat(location.root, &info) == 0 && info.st_mode & 0o777 == 0o700)
}

@Test func reviewShowsChangesDiffsAndConspicuousPaths() throws {
  let f = try Fixture()
  defer { f.cleanup() }
  try f.write("a.txt", "one\ntwo\nthree\n", in: f.destination)
  try f.write("a.txt", "one\n2\nthree\n", in: f.tree)
  try f.write(".git/hooks/pre-commit", "#!/bin/sh\n", in: f.tree, mode: 0o755)
  try f.write(".envrc", "export X=1\n", in: f.tree)
  try f.write("bidi\u{202E}txt.exe", "x", in: f.tree)
  try f.write("x\u{202E}/.envrc", "export Y=1\n", in: f.tree)
  let manifest = try f.build()
  let review = StageReview(manifest: manifest, tree: f.tree)
  let summary = review.summary(instance: "test")
  #expect(summary[1].contains("4 added, 1 modified, 0 type changes"))
  #expect(!summary.contains { $0.contains("pre-commit") })
  #expect(summary.contains { $0.contains("1 git administration entries") })
  #expect(summary.contains { $0.contains(".envrc") && $0.contains("withheld: direnv") })
  #expect(summary.contains { $0.contains("bidi?txt.exe") })
  #expect(!summary.joined().contains("\u{202E}"))
  #expect(review.applyCommand(instance: "t").contains("--approve-sensitive '.envrc'"))
  #expect(review.applyCommand(instance: "t").hasSuffix("--approve-sensitive 'x?/.envrc'"))
  #expect(!review.applyCommand(instance: "t").contains("\u{202E}"))
  let diffs = review.textDiffs()
  #expect(diffs.contains("--- a/a.txt"))
  #expect(diffs.contains("-two"))
  #expect(diffs.contains("+2"))
  #expect(!diffs.contains { $0.contains("stale") })
  try f.write("a.txt", "one\nTWO\nthree\n", in: f.destination)
  var stale = false
  _ = review.textDiffs(markOmitted: true, stale: &stale)
  #expect(stale)
}

@Test func hunksKeepThreeLinesOfContext() {
  let old = (1...20).map(String.init)
  var new = old
  new[9] = "ten"
  let hunks = StageReview.hunks(old: old, new: new)
  #expect(hunks.first == "@@ -7 +7 @@")
  #expect(hunks.filter { $0.hasPrefix(" ") }.count == 6)
  #expect(hunks.contains("-10") && hunks.contains("+ten"))
  #expect(StageReview.hunks(old: old, new: old).isEmpty)
}

/// Guest content cannot forge diff lines: `\r\n` is one `Character`, so a
/// `Character` split kept it inside a line and printed a second, unmarked
/// line; and canonically equivalent lines are still different bytes.
@Test func diffLinesSplitAtEveryLineFeedAndCompareBytes() throws {
  let new = try #require(StageReview.lines(Array("ok\nadded\r\n unchanged-looking\n".utf8)))
  #expect(new == ["ok", "added\r", " unchanged-looking"])
  let hunks = StageReview.hunks(old: ["ok"], new: new)
  #expect(hunks.allSatisfy { !$0.unicodeScalars.contains("\n") })
  #expect(hunks.contains("+ unchanged-looking"))
  // `String` equality would match these, so compare the rendered bytes.
  let equivalent = StageReview.hunks(old: ["x;", "e\u{301}"], new: ["x\u{37E}", "\u{E9}"])
    .map { Array($0.utf8) }
  for line in ["-x;", "+x\u{37E}", "-e\u{301}", "+\u{E9}"] {
    #expect(equivalent.contains(Array(line.utf8)), "\(line.debugDescription)")
  }
}

@Test func symlinkChainsCannotEscape() throws {
  let f = try Fixture()
  defer { f.cleanup() }
  try f.link("s", to: ".", in: f.tree)
  try f.link("x", to: "s/s/../../outside", in: f.tree)
  try f.link("l", to: "s/../outside", in: f.tree)
  try f.link("hostlink", to: "/", in: f.destination)
  try f.link("y", to: "hostlink/../etc", in: f.tree)
  let manifest = try f.build()
  #expect(!manifest.applicable)
  let chained = manifest.issues.filter { $0.contains("passes through another symlink") }
  #expect(chained.count == 3)
  #expect(manifest.issues.contains { $0.hasPrefix("y:") && $0.contains("(hostlink)") })
}

@Test func symlinkChainsAreDetectedCaseInsensitively() throws {
  let f = try Fixture()
  defer { f.cleanup() }
  try f.link("S", to: ".", in: f.tree)
  try f.link("x", to: "s/..", in: f.tree)
  let manifest = try f.build()
  #expect(!manifest.applicable)
  #expect(
    manifest.issues.contains { $0.hasPrefix("x:") && $0.contains("passes through another symlink") }
  )
}

/// APFS folds U+017F LATIN SMALL LETTER LONG S to `s`, which `lowercased()`
/// does not: `a/b/\u{17F}` is the link `a/b/s` there, so `notes.md` would
/// resolve outside the destination.
@Test func symlinkChainsAreDetectedUnderFullCaseFolding() throws {
  let f = try Fixture()
  defer { f.cleanup() }
  try f.write("secret", "host\n", in: f.outside)
  try f.link("a/b/s", to: "../..", in: f.tree)
  try f.link("notes.md", to: "a/b/\u{17F}/../outside/secret", in: f.tree)
  try f.link("k", to: ".", in: f.tree)
  try f.link("y", to: "\u{212A}/..", in: f.tree)
  let manifest = try f.build()
  #expect(!manifest.applicable)
  for link in ["notes.md", "y"] {
    #expect(
      manifest.issues.contains {
        $0.hasPrefix("\(link):") && $0.contains("passes through another symlink")
      })
  }
  #expect(throws: ReturnError.self) { try StageApplier(manifest: manifest, tree: f.tree).apply() }
  #expect(!FileManager.default.fileExists(atPath: f.destination + "/notes.md"))
}

/// A link component that only folds to a staged path costs one lookup, not a
/// scan of every staged entry.
@Test func caseVariantLinkTargetsStayCheap() throws {
  let f = try Fixture()
  defer { f.cleanup() }
  for index in 0..<2_000 { try f.write("a/f\(index)", "", in: f.tree) }
  let target = Array(repeating: "A/..", count: 200).joined(separator: "/")
  for index in 0..<40 { try f.link("l\(index)", to: target, in: f.tree) }
  let start = ContinuousClock.now
  let manifest = try f.build()
  #expect(ContinuousClock.now - start < .seconds(10))
  #expect(manifest.applicable)
}

/// A guest name that only folds (U+017F) to the host's existing entry is
/// refused, and the spelling check lists each destination directory once.
@Test func fullCaseFoldingSpellingsOfHostEntriesAreIssues() throws {
  let f = try Fixture()
  defer { f.cleanup() }
  try f.write("docs/a.txt", "a", in: f.destination)
  try f.write("doc\u{17F}/b.txt", "b", in: f.tree)
  try f.write(".vscode/settings.json", "{}", in: f.destination)
  try f.write(".v\u{17F}code/tasks.json", "{}", in: f.tree)
  let manifest = try f.build()
  #expect(!manifest.applicable)
  #expect(
    manifest.issues.contains {
      $0.hasPrefix("doc\u{17F}:") && $0.contains("differs only in case") && $0.hasSuffix("docs")
    })
  #expect(manifest.issues.contains { $0.hasPrefix(".v\u{17F}code:") && $0.hasSuffix(".vscode") })

  let flat = try Fixture()
  defer { flat.cleanup() }
  for index in 0..<300 {
    try flat.write("d/f\(index)", "x", in: flat.tree)
    try flat.write("d/f\(index)", "x", in: flat.destination)
  }
  var builder = try StageBuilder(tree: flat.tree, destination: flat.destination, limits: .defaults)
  _ = try builder.build(id: "0badf00d0badf00d", instance: "test")
  #expect(Set(builder.listings.keys) == ["", "d"])
}

@Test func stageLockSerializesUsersAndSurvivesStageRemoval() throws {
  let f = try Fixture()
  defer { f.cleanup() }
  let location = StageLocation(root: f.root + "/returns")
  try makeSelectedStage(location, destination: f.destination) { try f.write("a", "x", in: $0) }
  let first = try location.lock()
  let acquired = LockedBox(false)
  let done = DispatchSemaphore(value: 0)
  // A dedicated thread: a starved global queue under parallel tests can
  // delay the block past any fixed deadline.
  Thread {
    let second = try? location.lock()
    acquired.value = true
    second?.release()
    done.signal()
  }.start()
  Thread.sleep(forTimeInterval: 0.2)
  #expect(!acquired.value)
  try location.remove()
  #expect(FileManager.default.fileExists(atPath: f.root + "/.stage.lock"))
  first.release()
  #expect(done.wait(timeout: .now() + 60) == .success)
  #expect(acquired.value)
}

private final class LockedBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Bool
  init(_ value: Bool) { stored = value }
  var value: Bool {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}

@Test func growthGuardStopsATransferThatOutgrowsTheBudget() throws {
  let f = try Fixture()
  defer { f.cleanup() }
  let big = ByteCount(bytes: 1 << 30)!
  let entries = StageGrowthGuard(
    tree: f.tree, limits: StageLimits(maxFiles: 2, maxBytes: big, maxFileBytes: big))
  try f.write("a", "x", in: f.tree)
  #expect(!entries.shouldCancel())
  try f.write("b", "x", in: f.tree)
  try f.write("c", "x", in: f.tree)
  Thread.sleep(forTimeInterval: 0.6)
  #expect(entries.shouldCancel())
  #expect(entries.breachDescription?.contains("max_files") == true)

  let bytes = StageGrowthGuard(
    tree: f.tree,
    limits: StageLimits(maxFiles: 100, maxBytes: ByteCount(bytes: 4096)!, maxFileBytes: big))
  try f.write("big", String(repeating: "y", count: 64 << 10), in: f.tree)
  #expect(bytes.shouldCancel())
  #expect(bytes.breachDescription?.contains("max_bytes") == true)
}

@Test func deeplyNestedDirectoriesAreRefusedNotWalked() throws {
  let f = try Fixture()
  defer { f.cleanup() }
  let deep = Array(repeating: "d", count: StageBuilder.maxDepth + 2).joined(separator: "/")
  try f.write(deep + "/file", "x", in: f.tree)
  let manifest = try f.build()
  #expect(!manifest.applicable)
  #expect(manifest.issues.contains { $0.contains("nested deeper") })
}

@Test func swappedUnchangedParentIsRefusedBeforeWriting() throws {
  let f = try Fixture()
  defer { f.cleanup() }
  try f.write("a/keep", "k", in: f.destination)
  try f.write("a/keep", "k", in: f.tree)
  try f.write("a/x", "x", in: f.tree)
  try f.write("A.txt", "a", in: f.tree)
  let manifest = try f.build()
  try FileManager.default.removeItem(atPath: f.destination + "/a")
  try f.link("a", to: f.outside, in: f.destination)
  #expect(throws: ReturnError.self) { try StageApplier(manifest: manifest, tree: f.tree).apply() }
  #expect(!FileManager.default.fileExists(atPath: f.destination + "/A.txt"))
  #expect(!FileManager.default.fileExists(atPath: f.outside + "/x"))
}

@Test func conspicuousPathsIgnoreCase() {
  #expect(StageReview.conspicuous(".GIT/Hooks/post-checkout") != nil)
  #expect(StageReview.conspicuous("sub/.Git/CONFIG") != nil)
  #expect(StageReview.conspicuous("notgit/config") == nil)
  #expect(StageReview.conspicuous("x.git/config") == nil)
  #expect(StageReview.conspicuous(".git") != nil)
  #expect(StageReview.conspicuous("a/.git/modules/m/hooks/post-checkout") != nil)
  #expect(StageReview.conspicuous("sub/.ENVRC") != nil)
  #expect(StageReview.conspicuous(".husky/pre-commit") != nil)
  #expect(StageReview.conspicuous(".vscode/tasks.json") != nil)
  #expect(StageReview.conspicuous(".vscode/settings.json") == nil)
  // Full case folding, as APFS compares names: U+017F is `s`, U+212A is `k`.
  #expect(StageReview.conspicuous(".v\u{17F}code/ta\u{17F}ks.json") != nil)
  #expect(StageReview.conspicuous(".hu\u{17F}\u{212A}y/pre-commit") != nil)
  #expect(SensitivePaths.classify(".v\u{17F}code", new: .symlink(target: "vs")) != nil)
  // Code points APFS ignores still spell `.git`.
  #expect(ProtectedPaths.isReservedName(".g\u{200C}it"))
  #expect(ProtectedPaths.isReservedName(".GI\u{FEFF}T"))
  #expect(!ProtectedPaths.isReservedName(".gitignore"))
}

@Test func hugeTextDiffsAreSkipped() {
  let many = (0..<6_000).map(String.init)
  #expect(
    StageReview.hunks(old: many, new: many.reversed()) == ["(diff skipped: more than 10000 lines)"])
}

@Test func applyRefusesAStageOtherThanTheReviewedOne() throws {
  let f = try Fixture()
  defer { f.cleanup() }
  let instanceDirectory = f.root + "/instance"
  try FileManager.default.createDirectory(
    atPath: instanceDirectory, withIntermediateDirectories: true)
  let instance = Instance(
    name: try InstanceName("t"), index: InstanceIndex(1)!, directory: instanceDirectory,
    image: try ImageName("default"))
  let location = StageLocation(instance)
  let selected = try makeSelectedStage(location, destination: f.destination, instance: "t") {
    try f.write("a.txt", "guest", in: $0)
  }
  let id = selected.manifest.id
  let transfer = WorkspaceTransfer(
    client: SSHClient(environment: [:], tools: .searchPath),
    diagnostics: Diagnostics(verbosity: 0, sink: { _ in }))
  let error = try #require(throws: ReturnError.self) {
    try transfer.applyStage(instance, .init(stageID: "deadbeefdeadbeef", replace: true))
  }
  #expect(error.kind == .wrongStage && error.message.contains("not deadbeefdeadbeef"))
  #expect(!FileManager.default.fileExists(atPath: f.destination + "/a.txt"))
  #expect(location.exists)
  let (applied, paths) = try transfer.applyStage(instance, .init(stageID: id, replace: true))
  #expect(applied.id == id && paths == ["a.txt"])
  #expect(try f.read(f.destination + "/a.txt") == "guest")
  #expect(!location.exists)
}

@Test func manifestsFromAnotherVersionAreRefused() throws {
  let f = try Fixture()
  defer { f.cleanup() }
  let location = StageLocation(root: f.root + "/returns")
  let selected = try makeSelectedStage(location, destination: f.destination) {
    try f.write("a.txt", "x", in: $0)
  }
  try Data(
    #"{"version": 1, "id": "x", "instance": "t", "destination": "/d", "created_at": "", "exclude_git": false, "staged_entries": 0, "staged_bytes": 0, "changes": [], "issues": []}"#
      .utf8
  ).write(to: URL(fileURLWithPath: selected.stage.manifestPath))
  let error = try #require(throws: HostError.self) { try location.loadSelected() }
  #expect(error.message.contains("Unsupported stage manifest version 1"))
}
