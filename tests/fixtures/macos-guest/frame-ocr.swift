// Host-side oracle for Gates Q and R: the text visible in a computer-use
// frame, with each line's box in frame pixels (top-left origin).
//
//     frame-ocr FRAME.png   -> [{"text":..., "x":..., "y":..., "w":..., "h":..., "confidence":...}]
import AppKit
import Vision

let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let image = NSImage(contentsOf: url),
  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
  FileHandle.standardError.write(Data("cannot read \(url.path)\n".utf8))
  exit(1)
}
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
try VNImageRequestHandler(cgImage: cg).perform([request])
let w = Double(cg.width)
let h = Double(cg.height)
let lines: [[String: Any]] = (request.results ?? []).compactMap { o in
  guard let top = o.topCandidates(1).first else { return nil }
  let b = o.boundingBox
  return [
    "text": top.string, "confidence": Double(top.confidence), "x": b.minX * w,
    "y": (1 - b.maxY) * h, "w": b.width * w, "h": b.height * h,
  ]
}
print(String(decoding: try JSONSerialization.data(withJSONObject: lines), as: UTF8.self))
