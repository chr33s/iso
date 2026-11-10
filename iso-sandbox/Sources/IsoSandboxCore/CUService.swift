import Foundation
import IsoMacProtocol

/// Host computer-use requests against a ``VMScreen``, shared by the macOS
/// and Linux owners: the same session, frame, action, wait, hold and
/// live-view rules for both guest families. Each owner admits a session
/// first with its own guest-identity checks.
@MainActor
package enum CUService {
  /// Answers one computer-use request. `admit` runs before a session opens;
  /// a new live view starts only while `vmState` is `running`.
  package static func respond(
    _ req: MacControlRequest, screen: VMScreen, liveView: LiveViewSession?, vmState: String,
    admit: () async throws -> Void
  ) async -> MacControlResponse {
    do {
      return try await answer(
        req, screen: screen, liveView: liveView, vmState: vmState, admit: admit)
    } catch {
      return failure(error, op: req.op)
    }
  }

  /// A refused request, keeping the refusal code clients branch on.
  package static func failure(_ error: any Error, op: MacControlRequest.Op) -> MacControlResponse {
    var r = MacControlResponse(ok: false, error: "\(error)")
    if let e = error as? SandboxError, let refusal = e.refusal {
      r.refusal = refusal
      r.beforeInput = op == .cuAct ? e.beforeInput : nil
    }
    return r
  }

  private static func answer(
    _ req: MacControlRequest, screen: VMScreen, liveView: LiveViewSession?, vmState: String,
    admit: () async throws -> Void
  ) async throws -> MacControlResponse {
    var r = MacControlResponse(ok: true)
    switch req.op {
    case .cuSession:
      try await admit()
      let (id, binding) = try screen.newSession()
      r.session = id
      r.binding = binding
    case .cuFrame:
      let f = try screen.frame(session: req.session)
      r.frame = MacFrameInfo(
        frameId: f.id, seq: f.seq, width: screen.width, height: screen.height,
        bootId: f.binding.bootId, guestBoot: f.binding.guestBoot,
        vmInstance: f.binding.vmInstance, sha256: f.sha256, timestamp: f.timestamp, png: f.png,
        damageSeq: f.damageSeq)
      r.damageSeq = f.damageSeq
    case .cuAct:
      guard let action = req.action else {
        var e = SandboxError("cu-act needs an action", refusal: .invalidAction)
        e.beforeInput = true
        throw e
      }
      (r.submitted, r.damageSeq) = try await screen.act(
        session: req.session, request: action, basedOnFrame: req.basedOnFrame)
    case .cuStream:
      guard let liveView else { throw SandboxError("no live view in this owner") }
      guard vmState == "running" else { throw SandboxError("sandbox is \(vmState)") }
      r.streamURL = try liveView.start()
    case .cuStreamStop:
      liveView?.stop()
    case .cuWait:
      (r.wait, r.damageSeq) = try await screen.wait(
        session: req.session, since: req.since, idleMs: req.idleMs, timeoutMs: req.timeoutMs,
        until: req.until, region: req.region)
    case .cuHold:
      let seconds = req.seconds ?? CUControl.defaultHold
      guard CUControl.holdRange.contains(seconds) else {
        throw SandboxError(
          "hold must be \(CUControl.holdRange.lowerBound)-\(CUControl.holdRange.upperBound) seconds"
        )
      }
      screen.hold(.explicit, seconds: TimeInterval(seconds))
      (r.controller, r.holdRemainingSeconds) = screen.controlState
    case .cuRelease:
      screen.release()
      (r.controller, r.holdRemainingSeconds) = screen.controlState
    case .ping, .inspect, .status, .stop:
      throw SandboxError("\(req.op.rawValue) is not a computer-use request")
    }
    return r
  }
}
