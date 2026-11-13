import Foundation
import IsoMacProtocol

/// Host computer-use requests against a ``VMScreen``, shared by the macOS and
/// Linux owners: the same session, frame, action, wait, hold and live-view rules
/// for both guest families.
/// Each owner admits a session first with its own guest-identity checks.
@MainActor
package enum CUService {
  /// Whether the owner starts a new live view now.
  package enum StreamAdmission: Equatable, Sendable {
    case accepting
    /// Not while the VM is in `state` (starting, stopping, stopped).
    case refused(state: String)

    /// A new stream starts only in a running VM that is not being halted.
    package static func deciding(vmState: String, halting: Bool) -> StreamAdmission {
      if halting { return .refused(state: "stopping") }
      return vmState == "running" ? .accepting : .refused(state: vmState)
    }
  }

  /// Answers one computer-use request. `admit` runs before a session opens;
  /// a new live view starts only when `streams` accepts one.
  package static func respond(
    _ req: CURequest, screen: VMScreen, liveView: LiveViewSession?,
    streams: StreamAdmission, admit: () async throws -> Void
  ) async -> MacControlResponse {
    do {
      return try await answer(
        req, screen: screen, liveView: liveView, streams: streams, admit: admit)
    } catch {
      return failure(error, op: req.op)
    }
  }

  /// A refused request, keeping the refusal code clients branch on.
  package static func failure(_ error: any Error, op: CURequest.Op) -> MacControlResponse {
    var r = MacControlResponse(ok: false, error: "\(error)")
    if let e = error as? SandboxError, let refusal = e.refusal {
      r.refusal = refusal
      r.beforeInput = op == .act ? e.beforeInput : nil
    }
    return r
  }

  private static func answer(
    _ request: CURequest, screen: VMScreen, liveView: LiveViewSession?,
    streams: StreamAdmission, admit: () async throws -> Void
  ) async throws -> MacControlResponse {
    let req = request.fields
    var r = MacControlResponse(ok: true)
    switch request.op {
    case .session:
      try await admit()
      let (id, binding) = try screen.newSession()
      r.session = id
      r.binding = binding
    case .frame:
      let f = try screen.frame(session: req.session)
      r.frame = MacFrameInfo(
        frameId: f.id, seq: f.seq, width: screen.width, height: screen.height,
        bootId: f.binding.bootId, guestBoot: f.binding.guestBoot,
        vmInstance: f.binding.vmInstance, sha256: f.sha256, timestamp: f.timestamp, png: f.png,
        damageSeq: f.damageSeq)
      r.damageSeq = f.damageSeq
    case .act:
      guard let action = req.action else {
        var e = SandboxError("cu-act needs an action", refusal: .invalidAction)
        e.beforeInput = true
        throw e
      }
      (r.submitted, r.damageSeq) = try await screen.act(
        session: req.session, request: action, basedOnFrame: req.basedOnFrame)
    case .stream:
      guard let liveView else { throw SandboxError("no live view in this owner") }
      if case .refused(let state) = streams { throw SandboxError("sandbox is \(state)") }
      r.streamURL = try liveView.start()
    case .streamStop:
      liveView?.stop()
    case .wait:
      (r.wait, r.damageSeq) = try await screen.wait(session: req.session, req.wait)
    case .hold:
      let seconds = req.seconds ?? CUControl.defaultHold
      guard CUControl.holdRange.contains(seconds) else {
        throw SandboxError(
          "hold must be \(CUControl.holdRange.lowerBound)-\(CUControl.holdRange.upperBound) seconds"
        )
      }
      screen.hold(.explicit, seconds: TimeInterval(seconds))
      (r.controller, r.holdRemainingSeconds) = screen.controlState
    case .release:
      screen.release()
      (r.controller, r.holdRemainingSeconds) = screen.controlState
    }
    return r
  }
}
