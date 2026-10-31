import CoreGraphics
import Foundation
import ImageIO
import Vision

/// The dialog responder's transport over a running owner's control socket:
/// `cu-frame` plus local text recognition, and one `cu-act` click based on
/// the frame it was decided on. Recognition runs in this host process, on
/// the PNG the owner re-encoded at its fixed geometry.
package struct MacCUDialogTransport: CUDialogTransport {
  package var root: SandboxRoot
  package var id: SandboxID
  package var session: String

  package init(root: SandboxRoot, id: SandboxID, session: String) {
    self.root = root
    self.id = id
    self.session = session
  }

  private func call(_ req: MacControlRequest) throws(CUTransportFailure) -> MacControlResponse {
    do { return try MacSandboxes.cu(root: root, id: id, req) } catch { throw .lost }
  }

  /// A refused `cu-frame`: no observation this time (nil), unless the
  /// binding is void.
  static func frameFailure(_ r: MacControlResponse) -> CUTransportFailure? {
    r.refusal?.voidsBinding == true ? .invalidated(inputSent: false) : nil
  }

  /// A refused `cu-act`. Without a refusal before input, it may have pressed
  /// a button first.
  static func clickFailure(_ r: MacControlResponse) -> CUTransportFailure {
    guard let refusal = r.refusal else { return .lost }
    if r.beforeInput == true {
      return refusal.voidsBinding ? .invalidated(inputSent: false) : .refused
    }
    return refusal.voidsBinding ? .invalidated(inputSent: true) : .lost
  }

  package func observe(_ purpose: CUObservePurpose) async throws(CUTransportFailure)
    -> CUObservedFrame?
  {
    let r = try call(.init(op: .cuFrame, session: session))
    guard r.ok, let f = r.frame else {
      if let failure = Self.frameFailure(r) { throw failure }
      return nil
    }
    let observation: CUObservation
    do {
      // While waiting, a fast pass that finds no dialog words skips the
      // accurate one: a miss only means one more poll.
      if purpose == .waiting,
        !CUDialogClassifier.mayHoldDialog(try CUTextRecognition.lines(png: f.png, level: .fast))
      {
        observation = .none
      } else {
        observation = CUDialogClassifier.classify(
          try CUTextRecognition.lines(png: f.png, level: .accurate))
      }
    } catch { return nil }
    return CUObservedFrame(frameId: f.frameId, capturedAt: f.timestamp, observation: observation)
  }

  package func click(_ p: CUPoint, basedOnFrame frame: String) async throws(CUTransportFailure) {
    var action = CUActionRequest(kind: "click")
    action.x = p.x
    action.y = p.y
    let r = try call(.init(op: .cuAct, session: session, action: action, basedOnFrame: frame))
    guard r.ok else { throw Self.clickFailure(r) }
  }
}

/// Local, bounded text recognition over one frame.
package enum CUTextRecognition {
  package static func lines(png: Data, level: VNRequestTextRecognitionLevel = .accurate) throws
    -> [CUTextLine]
  {
    guard let src = CGImageSourceCreateWithData(png as CFData, nil),
      CGImageSourceGetType(src) as String? == "public.png", CGImageSourceGetCount(src) == 1,
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
      image.width == MacDisplay.width, image.height == MacDisplay.height
    else { throw SandboxError("frame is not a \(MacDisplay.width)x\(MacDisplay.height) PNG") }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = level
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: image).perform([request])
    let w = Double(image.width)
    let h = Double(image.height)
    return (request.results ?? []).prefix(CUDialogClassifier.maxLines + 1).compactMap { o in
      guard let top = o.topCandidates(1).first else { return nil }
      let b = o.boundingBox
      return CUTextLine(
        text: top.string, x: b.minX * w,
        y: (1 - b.maxY) * h, w: b.width * w, h: b.height * h)
    }
  }
}
