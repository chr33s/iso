import AppKit
import Foundation
import IsoMacProtocol
import Testing

@testable import IsoSandboxCore

private func line(_ text: String, _ x: Double, _ y: Double, w: Double = 120, h: Double = 18)
  -> CUTextLine
{
  CUTextLine(text: text, x: x, y: y, w: w, h: h)
}

/// A Terminal → Desktop TCC alert as OCR reports it: typographic quotes,
/// the sentence wrapped over two lines, two buttons below.
private func tccLines(
  requester: String = "Terminal", folder: String = "Desktop", dy: Double = 0
) -> [CUTextLine] {
  [
    line("\u{201C}\(requester)\u{201D} would like to access files in your", 800, 400 + dy, w: 320),
    line("\(folder) folder.", 880, 422 + dy, w: 140),
    line(
      "Keeping app data separate makes it easier to manage your privacy.", 790, 450 + dy, w: 340),
    line("Don\u{2019}t Allow", 820, 520 + dy, w: 90),
    line("Allow", 1000, 520 + dy, w: 50),
  ]
}

private let deny = CUPoint(x: 865, y: 529)
private let allow = CUPoint(x: 1025, y: 529)

private func terminalDesktop(_ r: CUDialogResponse = .allow) throws -> CUExpectation {
  try CUExpectation(requester: "Terminal", resource: .desktop, response: r)
}

@Test func aTCCFolderPromptIsRecognizedWithBothButtons() {
  #expect(
    CUDialogClassifier.classify(tccLines())
      == .consent(
        CUConsentDialog(requesterHint: "Terminal", resourceHint: .desktop, allow: allow, deny: deny)
      )
  )
  guard case .consent(let d) = CUDialogClassifier.classify(tccLines(folder: "Downloads")) else {
    Issue.record("not recognized")
    return
  }
  #expect(d.resourceHint == .downloads)
}

@Test func thePromptSentenceToleratesDroppedQuotesOnly() {
  #expect(
    CUDialogClassifier.parseFolderPrompt(
      "\"Terminal would like to access files in your Desktop folder.")?.0
      == "Terminal")
  #expect(
    CUDialogClassifier.parseFolderPrompt(
      "Terminal would like to access files in your Desktop folder")?.1
      == .desktop)
  #expect(
    CUDialogClassifier.parseFolderPrompt(
      "\"A\" \"B\" would like to access files in your Desktop folder.")
      == nil)
  #expect(CUDialogClassifier.parseFolderPrompt("Terminal would like to access your Desktop") == nil)
}

@Test func lookalikesAndIncompleteDialogsAreNotConsent() {
  // A lone Allow, anywhere, is not a dialog.
  #expect(CUDialogClassifier.classify([line("Allow", 1000, 520)]) == .none)
  // A prompt without its deny button.
  #expect(
    CUDialogClassifier.classify(tccLines().filter { $0.text != "Don\u{2019}t Allow" })
      == .ambiguous(.buttonsNotFound))
  // Buttons far from the sentence are not its buttons.
  var far = tccLines()
  far[4].x = 100
  far[4].y = 1100
  #expect(CUDialogClassifier.classify(far) == .ambiguous(.buttonsNotFound))
  // Two prompts, or two Allow buttons near one prompt.
  #expect(
    CUDialogClassifier.classify(tccLines() + tccLines(dy: 300)) == .ambiguous(.multiplePrompts))
  #expect(
    CUDialogClassifier.classify(tccLines() + [line("Allow", 1060, 560, w: 50)])
      == .ambiguous(.multiplePrompts))
  // An unknown folder or an unparsable sentence.
  #expect(
    CUDialogClassifier.classify(tccLines(folder: "Pictures")) == .ambiguous(.unparsedPrompt))
}

@Test func aFrameWithTooMuchTextIsNotClassified() {
  let filler = (0..<CUDialogClassifier.maxLines).map { line("x\($0)", 0, Double($0)) }
  #expect(CUDialogClassifier.classify(tccLines() + filler) == .ambiguous(.tooMuchText))
  #expect(
    CUDialogClassifier.classify(tccLines() + filler.dropFirst(tccLines().count))
      != .ambiguous(.tooMuchText))
}

@Test func aLineTooLongToReadWholeIsNotClassified() {
  let long = line(String(repeating: "x", count: 250) + " enter your password", 0, 0, w: 1900)
  #expect(CUDialogClassifier.classify(tccLines() + [long]) == .ambiguous(.tooMuchText))
}

@Test func authenticationKeychainAndSettingsDialogsAreBlocked() {
  #expect(
    CUDialogClassifier.classify(tccLines() + [line("Enter your password to allow this.", 800, 470)])
      == .blocked(.authentication))
  let keychain = [
    line("Terminal wants to use your confidential information stored in", 800, 400, w: 340),
    line("\u{201C}fixture-token\u{201D} in your keychain.", 800, 422),
    line("Always Allow", 800, 520), line("Deny", 950, 520), line("Allow", 1050, 520),
  ]
  #expect(CUDialogClassifier.classify(keychain) == .blocked(.keychain))
  #expect(
    CUDialogClassifier.classify(
      keychain + [
        line("To allow this, enter the \u{201C}login\u{201D} keychain password.", 800, 450)
      ]
    ) == .blocked(.authentication))
  #expect(
    CUDialogClassifier.classify(tccLines() + [line("Open System Settings", 900, 560)])
      == .blocked(.settings))
}

@Test func thePolicyMatchesRequesterAndResourceExactly() throws {
  let e = try terminalDesktop()
  let d = CUConsentDialog(
    requesterHint: "Terminal", resourceHint: .desktop, allow: allow, deny: deny)
  #expect(CUDialogPolicy.decide(.consent(d), e) == .respond(d))
  var other = d
  other.requesterHint = "Terminal Helper"
  #expect(CUDialogPolicy.decide(.consent(other), e) == .stop(.needsUser, .requesterMismatch))
  other = d
  other.resourceHint = .documents
  #expect(CUDialogPolicy.decide(.consent(other), e) == .stop(.needsUser, .resourceMismatch))
  #expect(
    CUDialogPolicy.decide(.blocked(.authentication), e)
      == .stop(.needsAuthentication, .authenticationRequired))
  #expect(
    CUDialogPolicy.decide(.blocked(.keychain), e)
      == .stop(.needsUser, .keychainNotQualified))
  #expect(
    CUDialogPolicy.decide(.blocked(.settings), e)
      == .stop(.setupRequired, .settingsRequired))
  #expect(CUDialogPolicy.decide(.none, e) == .stop(.needsUser, .noSupportedDialog))
  #expect(
    CUDialogPolicy.decide(.ambiguous(.unparsedPrompt), e) == .stop(.needsUser, .noSupportedDialog))
}

@Test func expectationsDecodeStrictly() throws {
  func decode(_ s: String) throws -> CUExpectation {
    try JSONDecoder().decode(CUExpectation.self, from: Data(s.utf8))
  }
  #expect(
    try decode(
      #"{"prompt":"tcc.folder_access","requester":"Terminal","resource":"desktop","response":"allow"}"#
    ) == terminalDesktop())
  for bad in [
    #"{"prompt":"tcc.folder_access","requester":"Terminal","resource":"desktop","response":"allow","persist":true}"#,
    #"{"prompt":"keychain.item_access","requester":"Terminal","resource":"desktop","response":"allow"}"#,
    #"{"prompt":"tcc.folder_access","requester":"","resource":"desktop","response":"allow"}"#,
    #"{"prompt":"tcc.folder_access","requester":"a\"b","resource":"desktop","response":"allow"}"#,
    #"{"prompt":"tcc.folder_access","requester":"Terminal","resource":"pictures","response":"allow"}"#,
    #"{"prompt":"tcc.folder_access","requester":"Terminal","resource":"desktop","response":"always"}"#,
  ] {
    #expect(throws: (any Error).self) { try decode(bad) }
  }
  // Each requester refusal on its own.
  for bad in [
    "", String(repeating: "a", count: 65), "Term\ninal", "a\"b", " Terminal", "Visual  Studio",
    "a\u{201C}b",
  ] {
    #expect(throws: SandboxError.self) {
      try CUExpectation(requester: bad, resource: .desktop, response: .allow)
    }
  }
  #expect(throws: Never.self) {
    try CUExpectation(
      requester: String(repeating: "a", count: 64), resource: .desktop, response: .allow)
  }
}

@Test func anAllowBehindTheAlertIsNotItsButton() {
  // OCR missed the alert's own Allow; a window behind has one within reach.
  var lines = tccLines().filter { $0.text != "Allow" }
  lines.append(line("Allow", 1100, 780, w: 50))
  #expect(CUDialogClassifier.classify(lines) == .ambiguous(.buttonsNotFound))
  // Stacked buttons, centred on one another, are a pair.
  var stacked = tccLines().filter { $0.text != "Allow" && $0.text != "Don\u{2019}t Allow" }
  stacked += [line("Allow", 860, 520, w: 200), line("Don\u{2019}t Allow", 860, 560, w: 200)]
  guard case .consent = CUDialogClassifier.classify(stacked) else {
    Issue.record("stacked buttons not recognized")
    return
  }
}

@Test func aSentenceWrappedInsideThePhraseIsRecognized() {
  let wrapped = [
    line("\u{201C}Visual Studio Code\u{201D} would like to", 800, 400, w: 320),
    line("access files in your Desktop folder.", 820, 422, w: 300),
    line("Don\u{2019}t Allow", 820, 520, w: 90), line("Allow", 1000, 520, w: 50),
  ]
  guard case .consent(let d) = CUDialogClassifier.classify(wrapped) else {
    Issue.record("not recognized")
    return
  }
  #expect(d.requesterHint == "Visual Studio Code")
  // "would like" in unrelated text is not a prompt.
  #expect(CUDialogClassifier.classify([line("I would like coffee", 10, 10)]) == .none)
}

@Test func aSentenceSplitOnOneRowIsJoinedInReadingOrder() {
  let split = [
    line("\u{201C}Terminal\u{201D} would like to access files in", 700, 400, w: 300),
    line("your Desktop folder.", 1001, 401, w: 160),
    line("Don\u{2019}t Allow", 820, 520, w: 90), line("Allow", 1000, 520, w: 50),
  ]
  guard case .consent(let d) = CUDialogClassifier.classify(split) else {
    Issue.record("not recognized")
    return
  }
  #expect(d.resourceHint == .desktop)
}

private func refused(_ code: CURefusal?, beforeInput: Bool? = nil) -> MacControlResponse {
  var r = MacControlResponse(ok: false, error: "refused")
  r.refusal = code
  r.beforeInput = beforeInput
  return r
}

private func failure(_ f: CUTransportFailure?) -> String { f.map { "\($0)" } ?? "nil" }

@Test func refusalCodesNotMessagesDecideTheTransportFailure() {
  // Frames: only a void binding stops; anything else is one missed frame.
  for code in [CURefusal.sessionRefused, .unknownSession, .unknownFrame, .helperGone, .noWindow] {
    #expect(
      failure(MacCUDialogTransport.frameFailure(refused(code))) == "invalidated(inputSent: false)")
  }
  #expect(MacCUDialogTransport.frameFailure(refused(.blankFrame)) == nil)
  #expect(MacCUDialogTransport.frameFailure(refused(nil)) == nil)
  // Clicks: refused before input is not attempted; anything else may be.
  #expect(
    failure(MacCUDialogTransport.clickFailure(refused(.busy, beforeInput: true))) == "refused")
  #expect(
    failure(MacCUDialogTransport.clickFailure(refused(.invalidAction, beforeInput: true)))
      == "refused")
  #expect(
    failure(MacCUDialogTransport.clickFailure(refused(.foreignFrame, beforeInput: true)))
      == "invalidated(inputSent: false)")
  #expect(
    failure(MacCUDialogTransport.clickFailure(refused(.sessionRefused, beforeInput: false)))
      == "invalidated(inputSent: true)")
  #expect(failure(MacCUDialogTransport.clickFailure(refused(nil))) == "lost")
  #expect(failure(MacCUDialogTransport.clickFailure(refused(.busy, beforeInput: false))) == "lost")
}

@Test func sessionRefusalsCarryTheirCode() {
  let b = CUBinding(
    bootId: "o1", vmInstance: "v1", guestBoot: "g1", helperGeneration: 1, width: 1920, height: 1200)
  func code(_ body: () throws -> Void) -> CURefusal? {
    do { try body() } catch let e as SandboxError { return e.refusal } catch {}
    return nil
  }
  var t = CUSessions()
  #expect(code { _ = try t.open(current: nil) } == .helperGone)
  #expect(code { _ = try t.check("nope", current: b) } == .unknownSession)
  let id = (try? t.open(current: b))?.0
  var other = b
  other.guestBoot = "g2"
  #expect(code { _ = try t.check(id, current: other) } == .sessionRefused)
  #expect(code { try t.requireFrame("f-1", from: b) } == .unknownFrame)
  let (frame, _) = t.recordFrame(other)
  #expect(code { try t.requireFrame(frame, from: b) } == .foreignFrame)
}

@Test func aQuickReadPassesOnlyFramesWithDialogWords() {
  #expect(CUDialogClassifier.mayHoldDialog(tccLines()))
  #expect(CUDialogClassifier.mayHoldDialog([line("Enter your password", 0, 0)]))
  #expect(!CUDialogClassifier.mayHoldDialog([line("ls ~/Desktop", 0, 0), line("Finder", 0, 30)]))
}

@Test func passwordTextOutsideTheAlertDoesNotBlockIt() {
  let sidebar = line("Touch ID & Password", 20, 300, w: 180)
  guard case .consent = CUDialogClassifier.classify(tccLines() + [sidebar]) else {
    Issue.record("blocked by text outside the alert")
    return
  }
  // With no consent prompt on screen, it still blocks.
  #expect(CUDialogClassifier.classify([sidebar]) == .blocked(.authentication))
}

// MARK: the response transaction

/// Time that moves only when the responder pauses.
private final class FakeClock: @unchecked Sendable {
  var t = Date(timeIntervalSince1970: 1_000_000)
}

private final class ScriptedTransport: CUDialogTransport {
  enum Step {
    case frame(CUObservation, age: TimeInterval = 0)
    case blank
    case fail(CUTransportFailure)
  }
  var steps: [Step]
  var clickResult: CUTransportFailure?
  var clicks: [(CUPoint, String)] = []
  var observed = 0
  let clock: FakeClock

  init(_ steps: [Step], click: CUTransportFailure? = nil, clock: FakeClock) {
    self.steps = steps
    clickResult = click
    self.clock = clock
  }

  func observe(_ purpose: CUObservePurpose) async throws(CUTransportFailure) -> CUObservedFrame? {
    observed += 1
    // The last step repeats once the script runs out.
    let step = steps.count > 1 ? steps.removeFirst() : steps[0]
    switch step {
    case .frame(let o, let age):
      return CUObservedFrame(
        frameId: "f\(observed)", capturedAt: clock.t.addingTimeInterval(-age), observation: o)
    case .blank: return nil
    case .fail(let f): throw f
    }
  }

  func click(_ p: CUPoint, basedOnFrame frame: String) async throws(CUTransportFailure) {
    clicks.append((p, frame))
    if let clickResult { throw clickResult }
  }
}

private let dialog = CUDialogClassifier.classify(tccLines())
private let moved = CUDialogClassifier.classify(tccLines(dy: 7))
private let finder = CUDialogClassifier.classify(tccLines(requester: "Finder"))

/// Runs a script against a responder that waits 3 s and verifies for 3 s,
/// one second per pause.
private func run(
  _ steps: [ScriptedTransport.Step], click: CUTransportFailure? = nil,
  mode: CUDialogMode = .auto, response: CUDialogResponse = .allow
) async throws -> (CUDialogReport, ScriptedTransport) {
  let clock = FakeClock()
  let t = ScriptedTransport(steps, click: click, clock: clock)
  var r = CUDialogResponder(
    mode: mode, expectation: try terminalDesktop(response), wait: 3, verifyWindow: 3)
  r.now = { clock.t }
  r.pause = { _ in clock.t.addTimeInterval(1) }
  return (try await r.run(t), t)
}

private func report(
  _ outcome: CUDialogOutcome, _ reason: CUDialogReason? = nil, attempted: Bool = false
) -> CUDialogReport {
  CUDialogReport(
    outcome: outcome, reason: reason, prompt: .tccFolderAccess, response: .allow,
    attempted: attempted)
}

@Test func anExpectedDialogGetsOneClickOnAFreshFrameAndIsVerifiedGone() async throws {
  let (r, t) = try await run([.blank, .frame(.none), .frame(dialog), .frame(dialog), .frame(.none)])
  #expect(r == report(.responded, attempted: true))
  #expect(t.clicks.count == 1)
  // Based on the re-observation, not the frame the decision came from.
  #expect(t.clicks.first?.0 == allow)
  #expect(t.clicks.first?.1 == "f4")
}

@Test func denyClicksTheDenyButton() async throws {
  let (r, t) = try await run([.frame(dialog), .frame(dialog), .frame(.none)], response: .deny)
  #expect(r.outcome == .responded)
  #expect(t.clicks.map(\.0) == [deny])
}

@Test func observeModeNeverClicks() async throws {
  let (r, t) = try await run([.frame(dialog)], mode: .observe)
  #expect(r == report(.proposed))
  #expect(t.clicks.isEmpty)
}

@Test func aPartlyDrawnDialogKeepsTheWaitGoing() async throws {
  let partial = CUObservation.ambiguous(.buttonsNotFound)
  let (r, t) = try await run([.frame(partial), .frame(dialog), .frame(dialog), .frame(.none)])
  #expect(r.outcome == .responded)
  #expect(t.clicks.count == 1)
  // Still ambiguous when the wait runs out: reported, not clicked.
  let (late, lt) = try await run([.frame(partial)])
  #expect(late == report(.needsUser, .buttonsNotFound))
  #expect(lt.clicks.isEmpty)
}

@Test func aDialogThatChangesBeforeTheClickIsNotClicked() async throws {
  // Moved past the tolerance, replaced by another app's prompt at the same
  // place, gone, or not observed.
  for second in [ScriptedTransport.Step.frame(moved), .frame(finder), .frame(.none), .blank] {
    let (r, t) = try await run([.frame(dialog), second, .frame(.none)])
    #expect(r == report(.needsUser, .dialogChanged))
    #expect(t.clicks.isEmpty)
  }
  // Within the tolerance it is the same dialog.
  let (r, t) = try await run([
    .frame(dialog), .frame(CUDialogClassifier.classify(tccLines(dy: 6))), .frame(.none),
  ])
  #expect(r.outcome == .responded)
  #expect(t.clicks.count == 1)
}

@Test func aStaleFrameIsNotClicked() async throws {
  let (stale, st) = try await run([.frame(dialog), .frame(dialog, age: 6)])
  #expect(stale.reason == .observationStale)
  #expect(st.clicks.isEmpty)
  // Timestamps travel in whole seconds: 5.9 s still counts as 5.
  let (fresh, ft) = try await run([.frame(dialog), .frame(dialog, age: 5.9), .frame(.none)])
  #expect(fresh.outcome == .responded)
  #expect(ft.clicks.count == 1)
}

@Test func aLostAcknowledgementIsNeverReplayed() async throws {
  let (gone, gt) = try await run([.frame(dialog), .frame(dialog), .frame(.none)], click: .lost)
  #expect(gone == report(.outcomeUnknown, .acknowledgementLost, attempted: true))
  #expect(gt.clicks.count == 1)
  let (stays, st) = try await run([.frame(dialog)], click: .lost)
  #expect(stays == report(.outcomeUnknown, .acknowledgementLost, attempted: true))
  #expect(st.clicks.count == 1)
}

@Test func onlyPositiveEvidenceCountsAsGone() async throws {
  // Blank and ambiguous frames after the click are not "gone".
  for after in [ScriptedTransport.Step.blank, .frame(.ambiguous(.buttonsNotFound)), .frame(dialog)]
  {
    let (r, t) = try await run([.frame(dialog), .frame(dialog), after])
    #expect(r == report(.outcomeUnknown, .dialogStillPresent, attempted: true))
    #expect(t.clicks.count == 1)
    #expect(t.observed == 5)
  }
  // A different request in its place means ours is gone.
  let (r, _) = try await run([.frame(dialog), .frame(dialog), .frame(finder)])
  #expect(r.outcome == .responded)
}

@Test func aSingleGoneFrameIsNotProof() async throws {
  let (r, t) = try await run([.frame(dialog), .frame(dialog), .frame(.none), .frame(dialog)])
  #expect(r == report(.outcomeUnknown, .dialogStillPresent, attempted: true))
  #expect(t.clicks.count == 1)
}

@Test func aDialogTheClickLeadsToIsReported() async throws {
  let (auth, _) = try await run([.frame(dialog), .frame(dialog), .frame(.blocked(.authentication))])
  #expect(auth == report(.needsAuthentication, .authenticationRequired, attempted: true))
  let (settings, _) = try await run([.frame(dialog), .frame(dialog), .frame(.blocked(.settings))])
  #expect(settings == report(.setupRequired, .settingsRequired, attempted: true))
}

@Test func transportFailuresAlwaysEndInAReport() async throws {
  let (before, bt) = try await run([.fail(.invalidated(inputSent: false))])
  #expect(before == report(.invalidated, .sessionInvalidated))
  #expect(bt.clicks.isEmpty)
  let (unreachable, ut) = try await run([.fail(.lost)])
  #expect(unreachable == report(.needsUser, .ownerUnreachable))
  #expect(ut.clicks.isEmpty)
  let (during, dt) = try await run(
    [.frame(dialog), .frame(dialog)], click: .invalidated(inputSent: true))
  #expect(during == report(.invalidated, .sessionInvalidated, attempted: true))
  let (early, _) = try await run(
    [.frame(dialog), .frame(dialog)], click: .invalidated(inputSent: false))
  #expect(early == report(.invalidated, .sessionInvalidated))
  #expect(dt.clicks.count == 1)
  let (reobserve, rt) = try await run([.frame(dialog), .fail(.invalidated(inputSent: false))])
  #expect(reobserve == report(.invalidated, .sessionInvalidated))
  #expect(rt.clicks.isEmpty)
  let (refused, _) = try await run([.frame(dialog), .frame(dialog)], click: .refused)
  #expect(refused == report(.needsUser, .inputRefused))
  // After the click, a failed observation is unknown, never responded.
  for f in [CUTransportFailure.lost, .invalidated(inputSent: false)] {
    let (after, at) = try await run([.frame(dialog), .frame(dialog), .fail(f)])
    #expect(after.outcome == .outcomeUnknown)
    #expect(after.attempted)
    #expect(at.clicks.count == 1)
  }
}

@Test func noDialogWithinTheWaitNeedsTheUser() async throws {
  let (r, t) = try await run([.frame(.none)])
  #expect(r == report(.needsUser, .noSupportedDialog))
  // At 0, 1, 2 and 3 s of a 3 s wait.
  #expect(t.observed == 4)
  #expect(t.clicks.isEmpty)
}

// MARK: recognition over a real frame

/// A frame at the owner's geometry with `texts` drawn at their top-left points.
private func renderedFrame(_ texts: [(String, Double, Double)]) throws -> Data {
  let w = MacDisplay.width
  let h = MacDisplay.height
  let rep = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSColor.white.setFill()
  NSRect(x: 0, y: 0, width: w, height: h).fill()
  let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black,
  ]
  for (text, x, y) in texts {
    NSAttributedString(string: text, attributes: attrs).draw(
      at: NSPoint(x: x, y: Double(h) - y - 22))
  }
  NSGraphicsContext.restoreGraphicsState()
  return try #require(rep.representation(using: .png, properties: [:]))
}

// Vision text recognition throws `nilError` on GitHub-hosted macOS runner VMs.
@Test(
  .disabled(
    if: ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
    "Vision text recognition is unavailable on hosted runners"))
func recognitionOverARenderedFrameFindsTheDialog() throws {
  let png = try renderedFrame([
    ("\u{201C}Terminal\u{201D} would like to access files in your Desktop folder.", 700, 400),
    ("Don\u{2019}t Allow", 760, 520), ("Allow", 1000, 520),
  ])
  guard case .consent(let d) = CUDialogClassifier.classify(try CUTextRecognition.lines(png: png))
  else {
    Issue.record("dialog not recognized")
    return
  }
  #expect(d.requesterHint == "Terminal")
  #expect(d.resourceHint == .desktop)
  #expect(abs(d.allow.y - 531) < 12)
  #expect(d.allow.x > 1000 && d.allow.x < 1060)
  #expect(d.deny.x > 760 && d.deny.x < 860)
}

@Test func recognitionRefusesAnythingButAFrameSizedPNG() {
  #expect(throws: SandboxError.self) { try CUTextRecognition.lines(png: Data("not a png".utf8)) }
}
