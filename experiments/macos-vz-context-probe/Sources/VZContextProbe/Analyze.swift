import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import ScreenCaptureKit

/// `analyze-frame <png> --layout <fixture-state.json>`: decode what the host
/// actually observed. Runs as its own process, after capture, so the owner's
/// return values never vouch for themselves.
///
/// Output: token and frame counter decoded from the barcodes (each cell
/// classified by its nearest calibration cell, which tolerates colour-space
/// conversion), the grid corners located from the magenta markers in the
/// pixels, and a blank-frame measure.
func analyzeFrame(_ args: Arguments) -> Never {
  guard let path = args.positional.first, let layoutPath = args.value("--layout"),
    let ld = FileManager.default.contents(atPath: layoutPath),
    let state = try? JSONSerialization.jsonObject(with: ld) as? [String: Any],
    let layout = state["layout"] as? [String: Any],
    let barcode = layout["barcode"] as? [String: Double],
    let screen = state["screen_px"] as? [String: Double]
  else { die("usage: analyze-frame <png> --layout <state.json>") }
  guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
  else {
    FileHandle.standardOutput.write(jsonLine(["ok": false, "error": "unreadable png"]))
    exit(1)
  }
  let w = image.width
  let h = image.height
  var px = [UInt8](repeating: 0, count: w * h * 4)
  px.withUnsafeMutableBytes { buf in
    let ctx = CGContext(
      data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .none
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
  }
  // Image pixels per guest screen pixel.
  // The layout comes from the guest: reject values that cannot describe this image.
  guard let bx = barcode["x"], let by = barcode["y"], let cell = barcode["cell"],
    let sw = screen["w"], let shh = screen["h"],
    [bx, by, cell, sw, shh].allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 100_000 }), sw >= 1,
    shh >= 1,
    cell >= 1, bx + 9 * cell <= sw, by + 5 * cell <= shh
  else {
    FileHandle.standardOutput.write(jsonLine(["ok": false, "error": "invalid layout"]))
    exit(1)
  }
  let sx = Double(w) / sw
  let sy = Double(h) / shh

  func pixel(_ x: Int, _ y: Int) -> [Int] {
    let cx = max(0, min(w - 1, x))
    let cy = max(0, min(h - 1, y))
    let o = (cy * w + cx) * 4
    return [Int(px[o]), Int(px[o + 1]), Int(px[o + 2])]
  }
  /// Median of a 3x3 sample around a guest-pixel coordinate.
  func sample(_ gx: Double, _ gy: Double) -> [Int] {
    let x = Int(gx * sx)
    let y = Int(gy * sy)
    var vals: [[Int]] = []
    for dx in [-3, 0, 3] { for dy in [-3, 0, 3] { vals.append(pixel(x + dx, y + dy)) } }
    return (0..<3).map { k in vals.map { $0[k] }.sorted()[4] }
  }
  func dist(_ a: [Int], _ b: [Int]) -> Double {
    Double(zip(a, b).map { ($0 - $1) * ($0 - $1) }.reduce(0, +)).squareRoot()
  }

  func at(_ col: Double, _ row: Double) -> [Int] { sample(bx + col * cell, by + row * cell) }
  let calib = (0..<4).map { at(Double($0) + 0.5, 0.5) }
  var spread = Double.infinity
  for i in 0..<4 { for j in (i + 1)..<4 { spread = min(spread, dist(calib[i], calib[j])) } }
  func decode(colOffset: Int) -> (UInt32, Double) {
    var v: UInt32 = 0
    var margin = Double.infinity
    for i in 0..<16 {
      let c = at(Double(colOffset + i % 4) + 0.5, Double(i / 4) + 1.5)
      let d = calib.enumerated().map { (dist(c, $0.element), $0.offset) }.sorted { $0.0 < $1.0 }
      margin = min(margin, d[1].0 - d[0].0)
      v = (v << 2) | UInt32(d[0].1)
    }
    return (v, margin)
  }
  let (tok, tokMargin) = decode(colOffset: 0)
  let (counter, ctrMargin) = decode(colOffset: 5)

  var mags: [(Double, Double)] = []
  for y in stride(from: 0, to: h, by: 1) {
    for x in stride(from: 0, to: w, by: 1) {
      let o = (y * w + x) * 4
      if px[o] > 200 && px[o + 1] < 70 && px[o + 2] > 200 {
        mags.append((Double(x) / sx, Double(y) / sy))
      }
    }
  }
  var corners: [String: [Double]] = [:]
  if !mags.isEmpty {
    let minX = mags.map(\.0).min()!
    let maxX = mags.map(\.0).max()!
    let minY = mags.map(\.1).min()!
    let maxY = mags.map(\.1).max()!
    let cx = (minX + maxX) / 2
    let cy = (minY + maxY) / 2
    for (name, f) in [
      ("tl", { (p: (Double, Double)) in p.0 < cx && p.1 < cy }),
      ("tr", { p in p.0 >= cx && p.1 < cy }),
      ("bl", { p in p.0 < cx && p.1 >= cy }), ("br", { p in p.0 >= cx && p.1 >= cy }),
    ] {
      let q = mags.filter(f)
      if !q.isEmpty {
        corners[name] = [
          q.map(\.0).reduce(0, +) / Double(q.count), q.map(\.1).reduce(0, +) / Double(q.count),
        ]
      }
    }
  }
  var gridObserved: Any = NSNull()
  if let tl = corners["tl"], let br = corners["br"], corners.count == 4 {
    gridObserved = ["x": tl[0], "y": tl[1], "w": br[0] - tl[0], "h": br[1] - tl[1]]
  }
  let digest = SHA256.hash(data: Data(px)).map { String(format: "%02x", $0) }.joined()
  let out: [String: Any] = [
    "ok": true, "image": [w, h], "scale": [sx, sy], "token": String(format: "%08x", tok),
    "token_margin": tokMargin, "counter": Int(counter), "counter_margin": ctrMargin,
    "calibration_spread": spread, "calibration": calib, "grid_observed": gridObserved,
    "marker_pixels": mags.count, "channel_range": channelRange(image) ?? NSNull(),
    "pixel_sha256": digest,
  ]
  FileHandle.standardOutput.write(jsonLine(out))
  exit(0)
}

/// `sck-capture --window-id N --out P`: O2 ScreenCaptureKit diagnostic control
/// (spec §12). A separate process, so its Screen Recording permission (TCC) is
/// its own and not the owner's.
func sckCapture(_ args: Arguments) -> Never {
  guard let wid = args.value("--window-id").flatMap(UInt32.init), let out = args.value("--out")
  else {
    die("usage: sck-capture --window-id N --out P")
  }
  Task {
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: false)
      guard let w = content.windows.first(where: { $0.windowID == wid }) else {
        FileHandle.standardOutput.write(
          jsonLine(["ok": false, "error": "window \(wid) not in shareable content"]))
        exit(1)
      }
      let cfg = SCStreamConfiguration()
      cfg.width = displayWidth
      cfg.height = displayHeight
      cfg.showsCursor = false
      cfg.ignoreShadowsSingleWindow = true
      let img = try await SCScreenshotManager.captureImage(
        contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg)
      guard
        let dest = CGImageDestinationCreateWithURL(
          URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)
      else { die("png destination") }
      CGImageDestinationAddImage(dest, img, nil)
      CGImageDestinationFinalize(dest)
      FileHandle.standardOutput.write(
        jsonLine(["ok": true, "path": out, "image_width": img.width, "image_height": img.height]))
      exit(0)
    } catch {
      FileHandle.standardOutput.write(jsonLine(["ok": false, "error": errorInfo(error)]))
      exit(1)
    }
  }
  dispatchMain()
}
