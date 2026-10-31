import Foundation

// Guest permission-dialog responder (docs/design/permission-dialog-auto-response.md).
// Recognition, policy and the response transaction are pure here; the
// transport (frames, OCR, one click) is injected so every outcome is
// unit-testable. Recognized text is guest-rendered data: it selects a
// candidate but never widens what the caller's expectation allows.

/// One recognized text line, in frame pixels (top-left origin).
package struct CUTextLine: Equatable, Sendable {
  package var text: String
  package var x: Double
  package var y: Double
  package var w: Double
  package var h: Double

  package init(text: String, x: Double, y: Double, w: Double, h: Double) {
    self.text = text
    self.x = x
    self.y = y
    self.w = w
    self.h = h
  }

  var center: CUPoint { CUPoint(x: x + w / 2, y: y + h / 2) }
  var maxX: Double { x + w }
  var maxY: Double { y + h }

  /// Typographic quotes folded to ASCII, whitespace collapsed.
  var normalized: String {
    let folded = text.map { c -> Character in
      switch c {
      case "\u{2018}", "\u{2019}": "'"
      case "\u{201C}", "\u{201D}": "\""
      default: c
      }
    }
    return String(folded).split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}

package enum CUPromptFamily: String, Codable, Sendable {
  case tccFolderAccess = "tcc.folder_access"
  /// Recognized, so a caller asking for it gets a clear refusal; not qualified.
  case keychainItemAccess = "keychain.item_access"
}

/// The folders a TCC folder-access prompt names.
package enum CUFolder: String, Codable, Sendable, CaseIterable {
  case desktop, documents, downloads

  var displayName: String {
    switch self {
    case .desktop: "Desktop"
    case .documents: "Documents"
    case .downloads: "Downloads"
    }
  }
}

package enum CUDialogResponse: String, Codable, Sendable { case allow, deny }

package enum CUDialogMode: String, Sendable, CaseIterable { case observe, auto }

/// The one prompt a caller has just triggered and the response it chose in
/// advance. Only qualified prompt families decode; unknown fields are refused.
package struct CUExpectation: Decodable, Equatable, Sendable {
  package var prompt: CUPromptFamily { .tccFolderAccess }
  /// The application name the prompt must display, exactly.
  package let requester: String
  package let resource: CUFolder
  package let response: CUDialogResponse

  package static let maxRequester = 64

  package init(requester: String, resource: CUFolder, response: CUDialogResponse) throws {
    guard !requester.isEmpty, requester.count <= Self.maxRequester,
      !requester.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      !requester.contains("\""),
      requester == CUTextLine(text: requester, x: 0, y: 0, w: 0, h: 0).normalized
    else {
      throw SandboxError(
        "requester must be 1-\(Self.maxRequester) printable characters, single-spaced, no quotes")
    }
    self.requester = requester
    self.resource = resource
    self.response = response
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case prompt, requester, resource, response
  }

  private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  package init(from decoder: any Decoder) throws {
    let known = Set(CodingKeys.allCases.map(\.rawValue))
    for key in try decoder.container(keyedBy: AnyKey.self).allKeys
    where !known.contains(key.stringValue) {
      throw SandboxError("unknown expectation field \(key.stringValue.debugDescription)")
    }
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let prompt = try c.decode(CUPromptFamily.self, forKey: .prompt)
    guard prompt == .tccFolderAccess else {
      throw SandboxError("prompt \(prompt.rawValue) is not supported for automatic response")
    }
    try self.init(
      requester: try c.decode(String.self, forKey: .requester),
      resource: try c.decode(CUFolder.self, forKey: .resource),
      response: try c.decode(CUDialogResponse.self, forKey: .response))
  }
}

/// A recognized consent dialog with both of its buttons.
package struct CUConsentDialog: Equatable, Sendable {
  package var requesterHint: String
  package var resourceHint: CUFolder
  package var allow: CUPoint
  package var deny: CUPoint

  package func target(_ r: CUDialogResponse) -> CUPoint { r == .allow ? allow : deny }

  func sameRequest(_ other: CUConsentDialog) -> Bool {
    requesterHint == other.requesterHint && resourceHint == other.resourceHint
  }
}

/// Dialogs this responder recognizes but never answers.
package enum CUBlockedFamily: Sendable { case keychain, authentication, settings }

/// Why a frame with a prompt sentence is not a usable consent dialog.
package enum CUAmbiguity: Sendable {
  case multiplePrompts, buttonsNotFound, unparsedPrompt, tooMuchText
}

package enum CUObservation: Equatable, Sendable {
  case none
  case ambiguous(CUAmbiguity)
  case blocked(CUBlockedFamily)
  case consent(CUConsentDialog)
}

package enum CUDialogOutcome: String, Codable, Sendable {
  /// Observe mode: the response auto mode would submit.
  case proposed
  /// One response submitted and the dialog gone. The caller still checks
  /// the operation's own result before resuming.
  case responded
  case needsUser = "needs_user"
  case needsAuthentication = "needs_authentication"
  case setupRequired = "setup_required"
  case outcomeUnknown = "outcome_unknown"
  case invalidated
}

package enum CUDialogReason: String, Codable, Sendable {
  case noSupportedDialog = "no_supported_dialog"
  case multiplePrompts = "multiple_prompts"
  case buttonsNotFound = "buttons_not_found"
  case tooMuchText = "too_much_text"
  case requesterMismatch = "requester_mismatch"
  case resourceMismatch = "resource_mismatch"
  case keychainNotQualified = "keychain_not_qualified"
  case authenticationRequired = "authentication_required"
  case settingsRequired = "settings_required"
  case dialogChanged = "dialog_changed"
  case observationStale = "observation_stale"
  case inputRefused = "input_refused"
  case sessionInvalidated = "session_invalidated"
  case ownerUnreachable = "owner_unreachable"
  case acknowledgementLost = "acknowledgement_lost"
  case dialogStillPresent = "dialog_still_present"
  case cancelled

  init(_ a: CUAmbiguity) {
    self =
      switch a {
      case .multiplePrompts: .multiplePrompts
      case .buttonsNotFound: .buttonsNotFound
      case .unparsedPrompt: .noSupportedDialog
      case .tooMuchText: .tooMuchText
      }
  }
}

/// Pixel-text recognition of the supported prompt families (English).
package enum CUDialogClassifier {
  package static let maxLines = 512
  package static let maxLineLength = 256
  /// How far from the prompt sentence its buttons may sit, in frame pixels.
  static let reachX = 320.0
  static let reachBelow = 420.0

  private static let keychainMarkers = [
    "wants to use your confidential information", "wants to access key",
  ]
  private static let authenticationMarkers = [
    "wants to make changes", "enter your password", "enter the password", "touch id",
    "use password",
  ]

  package static func classify(_ lines: [CUTextLine]) -> CUObservation {
    // Truncated text could hide a blocking marker.
    guard lines.count <= maxLines, lines.allSatisfy({ $0.text.count <= maxLineLength }) else {
      return .ambiguous(.tooMuchText)
    }
    let texts = lines.map(\.normalized)
    let lower = texts.map { $0.lowercased() }
    // Blocking families before consent: none of these is ever answered.
    if lower.contains(where: { l in keychainMarkers.contains { l.contains($0) } }) {
      return lower.contains { $0.contains("password") }
        ? .blocked(.authentication) : .blocked(.keychain)
    }
    if texts.contains("Open System Settings") { return .blocked(.settings) }

    // The sentence may wrap anywhere, even inside "would like to access":
    // start from every line with "would like" and keep those that parse.
    let starts = lines.indices.filter { lower[$0].contains("would like") }
    let prompts = starts.compactMap { a in
      parseFolderPrompt(sentence(from: a, lines, texts)).map { (a, $0.0, $0.1) }
    }
    let authentication = lines.indices.filter { i in
      authenticationMarkers.contains { lower[i].contains($0) }
    }
    guard let (a, requester, folder) = prompts.first else {
      if !authentication.isEmpty { return .blocked(.authentication) }
      return starts.contains { lower[$0].contains("would like to access") }
        ? .ambiguous(.unparsedPrompt) : .none
    }
    guard prompts.count == 1 else { return .ambiguous(.multiplePrompts) }
    let anchor = lines[a]
    func inAlert(_ l: CUTextLine) -> Bool {
      let c = l.center
      return c.x > anchor.x - reachX && c.x < anchor.maxX + reachX
        && c.y > anchor.y - anchor.h * 3 && c.y < anchor.maxY + reachBelow
    }
    // Password text in the alert blocks it; elsewhere on screen (a Settings
    // sidebar, terminal output) it does not.
    if authentication.contains(where: { inAlert(lines[$0]) }) { return .blocked(.authentication) }
    func below(_ l: CUTextLine) -> Bool { inAlert(l) && l.center.y > anchor.y }
    let allow = lines.indices.filter { texts[$0] == "Allow" && below(lines[$0]) }
    let deny = lines.indices.filter { texts[$0] == "Don't Allow" && below(lines[$0]) }
    guard allow.count == 1, deny.count == 1 else {
      return .ambiguous(allow.count > 1 || deny.count > 1 ? .multiplePrompts : .buttonsNotFound)
    }
    // An alert's two buttons sit side by side or stacked; an Allow elsewhere
    // within reach (a window behind the alert) is not this alert's button.
    guard buttonPair(lines[allow[0]], lines[deny[0]]) else { return .ambiguous(.buttonsNotFound) }
    return .consent(
      CUConsentDialog(
        requesterHint: requester, resourceHint: folder, allow: lines[allow[0]].center,
        deny: lines[deny[0]].center))
  }

  /// Whether a quick read shows any word a supported or blocking dialog has.
  package static func mayHoldDialog(_ lines: [CUTextLine]) -> Bool {
    lines.contains { l in
      let t = l.normalized.lowercased()
      return ["would like", "allow", "password", "keychain", "touch id", "settings", "wants to"]
        .contains { t.contains($0) }
    }
  }

  /// The anchor joined with what OCR split off it: to its right on the same
  /// row, or wrapped onto the next rows, in reading order.
  static func sentence(from a: Int, _ lines: [CUTextLine], _ texts: [String]) -> String {
    let anchor = lines[a]
    guard anchor.h > 0 else { return texts[a] }
    let row = { (l: CUTextLine) in ((l.y - anchor.y) / anchor.h).rounded() }
    let continuation = lines.indices.filter { i in
      let l = lines[i]
      guard i != a, l.maxX > anchor.x - reachX, l.x < anchor.maxX + reachX else { return false }
      return row(l) == 0 ? l.x >= anchor.maxX - 1 : row(l) > 0 && l.y < anchor.maxY + anchor.h * 2.5
    }.sorted { (row(lines[$0]), lines[$0].x) < (row(lines[$1]), lines[$1].x) }.prefix(2)
    return ([a] + continuation).map { texts[$0] }.joined(separator: " ")
  }

  static func buttonPair(_ a: CUTextLine, _ d: CUTextLine) -> Bool {
    let (ca, cd) = (a.center, d.center)
    let sideBySide = abs(ca.y - cd.y) <= max(a.h, d.h) && abs(ca.x - cd.x) <= 360
    let stacked = abs(ca.x - cd.x) <= 12 && abs(ca.y - cd.y) <= 80
    return sideBySide || stacked
  }

  /// `"NAME" would like to access files in your FOLDER folder.` OCR may
  /// drop either quote mark; the name itself may contain none.
  static func parseFolderPrompt(_ s: String) -> (String, CUFolder)? {
    guard let r = s.range(of: " would like to access files in your ") else { return nil }
    var name = Substring(s[..<r.lowerBound])
    if name.first == "\"" { name = name.dropFirst() }
    if name.last == "\"" { name = name.dropLast() }
    guard !name.isEmpty, name.count <= CUExpectation.maxRequester, !name.contains("\"") else {
      return nil
    }
    let tail = s[r.upperBound...]
    return CUFolder.allCases.first { tail.hasPrefix("\($0.displayName) folder") }.map {
      (String(name), $0)
    }
  }
}

package enum CUDialogDecision: Equatable, Sendable {
  case respond(CUConsentDialog)
  case stop(CUDialogOutcome, CUDialogReason)
}

package enum CUDialogPolicy {
  package static func decide(_ o: CUObservation, _ e: CUExpectation) -> CUDialogDecision {
    switch o {
    case .none: return .stop(.needsUser, .noSupportedDialog)
    case .ambiguous(let why): return .stop(.needsUser, CUDialogReason(why))
    case .blocked(let family):
      let (outcome, why) = blocked(family)
      return .stop(outcome, why)
    case .consent(let d):
      guard d.requesterHint == e.requester else { return .stop(.needsUser, .requesterMismatch) }
      guard d.resourceHint == e.resource else { return .stop(.needsUser, .resourceMismatch) }
      return .respond(d)
    }
  }

  static func blocked(_ f: CUBlockedFamily) -> (CUDialogOutcome, CUDialogReason) {
    switch f {
    case .authentication: (.needsAuthentication, .authenticationRequired)
    case .settings: (.setupRequired, .settingsRequired)
    case .keychain: (.needsUser, .keychainNotQualified)
    }
  }

  /// Button positions may move this far between the decision and the click.
  static let tolerance = 6.0

  /// The dialog in `now` if it is still the one the decision was made on.
  package static func current(_ before: CUConsentDialog, in now: CUObservation)
    -> CUConsentDialog?
  {
    guard case .consent(let d) = now else { return nil }
    func close(_ a: CUPoint, _ b: CUPoint) -> Bool {
      abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }
    return d.sameRequest(before) && close(d.allow, before.allow) && close(d.deny, before.deny)
      ? d : nil
  }
}

/// A recognized frame, ready for a decision.
package struct CUObservedFrame: Sendable {
  package var frameId: String
  package var capturedAt: Date
  package var observation: CUObservation

  package init(frameId: String, capturedAt: Date, observation: CUObservation) {
    self.frameId = frameId
    self.capturedAt = capturedAt
    self.observation = observation
  }
}

package enum CUTransportFailure: Error {
  /// The session or frame binding was refused; any decision is void.
  /// `inputSent`: the refusal came part-way through the click.
  case invalidated(inputSent: Bool)
  /// A click refused before any input was sent (for example another action
  /// in progress).
  case refused
  /// No usable reply. For a click, it may or may not have been delivered.
  case lost
}

package enum CUObservePurpose: Sendable {
  /// Waiting for the dialog to appear: a miss costs one more poll.
  case waiting
  /// Deciding to click, or checking the dialog went: every frame counts.
  case confirming
}

/// What the responder needs from the VM: recognized frames and one click.
package protocol CUDialogTransport {
  /// Nil when no usable frame was available this time (for example blank).
  func observe(_ purpose: CUObservePurpose) async throws(CUTransportFailure) -> CUObservedFrame?
  func click(_ p: CUPoint, basedOnFrame: String) async throws(CUTransportFailure)
}

package struct CUDialogReport: Codable, Equatable, Sendable {
  package var outcome: CUDialogOutcome
  package var reason: CUDialogReason?
  package var prompt: CUPromptFamily
  package var response: CUDialogResponse
  /// Whether input may have reached the guest. Never more than one click.
  package var attempted: Bool
}

/// One prompt occurrence: observe, decide, re-observe, at most one click,
/// then verify. A click is never repeated, whatever happens after it.
package struct CUDialogResponder {
  package let mode: CUDialogMode
  package let expectation: CUExpectation
  /// How long to wait for the dialog to appear, and to go after the click.
  package let wait: TimeInterval
  package let verifyWindow: TimeInterval
  package var interval: Duration = .milliseconds(700)
  /// Oldest a frame may be when the click is based on it. Owner timestamps
  /// travel in whole seconds, so up to one more second is allowed.
  package var maxAge: TimeInterval = 5
  package var now: @Sendable () -> Date = { Date() }
  package var pause: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

  package init(
    mode: CUDialogMode, expectation: CUExpectation, wait: TimeInterval, verifyWindow: TimeInterval
  ) {
    self.mode = mode
    self.expectation = expectation
    self.wait = wait
    self.verifyWindow = verifyWindow
  }

  private func report(
    _ outcome: CUDialogOutcome, _ reason: CUDialogReason? = nil, attempted: Bool = false
  ) -> CUDialogReport {
    CUDialogReport(
      outcome: outcome, reason: reason, prompt: expectation.prompt,
      response: expectation.response, attempted: attempted)
  }

  package func run(_ t: some CUDialogTransport) async throws -> CUDialogReport {
    do {
      return try await transaction(t)
    } catch let f as CUTransportFailure {
      // Transport failures reach here only from observations before the click.
      if case .invalidated = f { return report(.invalidated, .sessionInvalidated) }
      return report(.needsUser, .ownerUnreachable)
    }
  }

  private static func reason(_ f: CUTransportFailure) -> CUDialogReason {
    if case .invalidated = f { return .sessionInvalidated }
    return .ownerUnreachable
  }

  /// Polls until a dialog is recognized or `wait` runs out; a partly drawn
  /// dialog (ambiguous) keeps polling and is reported only at the end.
  private func firstObservation(_ t: some CUDialogTransport) async throws -> CUObservation {
    let deadline = now().addingTimeInterval(wait)
    var last: CUObservation = .none
    while true {
      if let o = try await t.observe(.waiting)?.observation {
        switch o {
        case .consent, .blocked: return o
        case .ambiguous: last = o
        case .none: break
        }
      }
      if now() >= deadline { return last }
      try await pause(interval)
    }
  }

  private func transaction(_ t: some CUDialogTransport) async throws -> CUDialogReport {
    let dialog: CUConsentDialog
    switch CUDialogPolicy.decide(try await firstObservation(t), expectation) {
    case .stop(let outcome, let why): return report(outcome, why)
    case .respond(let d): dialog = d
    }
    if mode == .observe { return report(.proposed) }

    // Re-observe immediately before acting: the click is based on this frame.
    guard let fresh = try await t.observe(.confirming),
      let current = CUDialogPolicy.current(dialog, in: fresh.observation)
    else { return report(.needsUser, .dialogChanged) }
    guard now().timeIntervalSince(fresh.capturedAt) < maxAge + 1 else {
      return report(.needsUser, .observationStale)
    }
    var lost = false
    do {
      try await t.click(current.target(expectation.response), basedOnFrame: fresh.frameId)
    } catch .refused {
      return report(.needsUser, .inputRefused)
    } catch .invalidated(let sent) {
      return report(.invalidated, .sessionInvalidated, attempted: sent)
    } catch .lost {
      lost = true
    }
    return try await verify(t, dialog, lost: lost)
  }

  /// "Gone" needs positive evidence: no prompt sentence, or a different
  /// request. An ambiguous frame (a button highlighted, a fade) is not gone.
  private func verify(_ t: some CUDialogTransport, _ dialog: CUConsentDialog, lost: Bool)
    async throws -> CUDialogReport
  {
    let deadline = now().addingTimeInterval(verifyWindow)
    // Two gone frames in a row: one OCR miss is not proof.
    var goneFrames = 0
    while true {
      do { try await pause(interval) } catch {
        return report(.outcomeUnknown, .cancelled, attempted: true)
      }
      let observed: CUObservedFrame?
      do { observed = try await t.observe(.confirming) } catch {
        return report(.outcomeUnknown, Self.reason(error), attempted: true)
      }
      let gone: Bool
      switch observed?.observation {
      case .none?: gone = true
      case .consent(let d)?: gone = !d.sameRequest(dialog)
      case .blocked(let family)?:
        // The click led on to a dialog this responder never answers.
        let (outcome, why) = CUDialogPolicy.blocked(family)
        return report(outcome, why, attempted: true)
      case .ambiguous?, nil: gone = false
      }
      goneFrames = gone ? goneFrames + 1 : 0
      if goneFrames == 2 {
        return lost
          ? report(.outcomeUnknown, .acknowledgementLost, attempted: true)
          : report(.responded, attempted: true)
      }
      if now() >= deadline { break }
    }
    return report(
      .outcomeUnknown, lost ? .acknowledgementLost : .dialogStillPresent, attempted: true)
  }
}
