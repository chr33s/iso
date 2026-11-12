import Accelerate
import AppKit
import IOSurface
import QuartzCore

/// Reads a guest's framebuffer from the IOSurface VZ sets as the `contents`
/// of the layer under a `VZVirtualMachineView` (its private
/// `_VZFramebufferView`, macOS 27.2), ignoring the alpha byte
/// (docs/design/linux-desktop-virtio-gpu.md §3, §6).
///
/// The pixels are the hypervisor's copy of the guest's scanout. The owner
/// parses nothing guest-authored here: it checks the surface's geometry and
/// format, which VZ sets, and copies a fixed-size buffer. The structure is
/// undocumented, so every miss is a typed failure and never a fallback.
enum FramebufferSurface {
  /// `'BGRA'`: the format VZ gives the surface for an XRGB8888 scanout.
  static let pixelFormat: OSType = 0x4247_5241

  enum Failure: Error, Equatable, CustomStringConvertible {
    /// No IOSurface-backed layer under the view.
    case notFound
    case geometry(width: Int, height: Int)
    case format(OSType)
    case lock(Int32)

    var description: String {
      switch self {
      case .notFound: "no IOSurface-backed layer under the view"
      case .geometry(let w, let h): "the framebuffer surface is \(w)x\(h)"
      case .format(let f): "the framebuffer surface has pixel format \(String(f, radix: 16))"
      case .lock(let r): "the framebuffer surface did not lock (\(r))"
      }
    }
  }

  /// The surface under `view`, looked up on every call: VZ rotates
  /// between surfaces while the guest redraws.
  @MainActor
  static func find(under view: NSView) -> IOSurfaceRef? {
    func inLayer(_ layer: CALayer) -> IOSurfaceRef? {
      if let contents = layer.contents,
        CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID()
      {
        return unsafeBitCast(contents as CFTypeRef, to: IOSurfaceRef.self)
      }
      for sub in layer.sublayers ?? [] {
        if let found = inLayer(sub) { return found }
      }
      return nil
    }
    func inView(_ v: NSView) -> IOSurfaceRef? {
      if let layer = v.layer, let found = inLayer(layer) { return found }
      for sub in v.subviews {
        if let found = inView(sub) { return found }
      }
      return nil
    }
    return inView(view)
  }

  /// Copies the framebuffer under `view` into `destination` as RGBX (R, G,
  /// B, 0xFF per pixel), `width` by `height`.
  @MainActor
  static func read(
    under view: NSView, width: Int, height: Int, into destination: UnsafeMutableRawPointer,
    bytesPerRow: Int
  ) throws(Failure) {
    guard let surface = find(under: view) else { throw .notFound }
    try read(surface, width: width, height: height, into: destination, bytesPerRow: bytesPerRow)
  }

  /// Copies `surface` into `destination`, which holds `width` by `height`
  /// pixels and no more: a surface of any other size or pixel format is
  /// refused, never copied or scaled.
  static func read(
    _ surface: IOSurfaceRef, width: Int, height: Int,
    into destination: UnsafeMutableRawPointer, bytesPerRow: Int
  ) throws(Failure) {
    let w = IOSurfaceGetWidth(surface)
    let h = IOSurfaceGetHeight(surface)
    guard w == width, h == height else { throw .geometry(width: w, height: h) }
    let format = IOSurfaceGetPixelFormat(surface)
    guard format == pixelFormat else { throw .format(format) }
    let locked = IOSurfaceLock(surface, .readOnly, nil)
    guard locked == KERN_SUCCESS else { throw .lock(locked) }
    defer { IOSurfaceUnlock(surface, .readOnly, nil) }
    convert(
      bgra: IOSurfaceGetBaseAddress(surface), bytesPerRow: IOSurfaceGetBytesPerRow(surface),
      into: destination, bytesPerRow: bytesPerRow, width: width, height: height)
  }

  /// BGRA (B, G, R, A in memory) to RGBX with X = 0xFF: the alpha byte is
  /// ignored, so a guest that leaves it at 0 still reads as opaque.
  static func convert(
    bgra source: UnsafeRawPointer, bytesPerRow sourceRow: Int,
    into destination: UnsafeMutableRawPointer, bytesPerRow destinationRow: Int, width: Int,
    height: Int
  ) {
    var src = vImage_Buffer(
      data: UnsafeMutableRawPointer(mutating: source), height: vImagePixelCount(height),
      width: vImagePixelCount(width), rowBytes: sourceRow)
    var dst = vImage_Buffer(
      data: destination, height: vImagePixelCount(height), width: vImagePixelCount(width),
      rowBytes: destinationRow)
    // Channel i of the output is channel map[i] of the input.
    let map: [UInt8] = [2, 1, 0, 3]
    vImagePermuteChannels_ARGB8888(&src, &dst, map, vImage_Flags(kvImageNoFlags))
    // 0x1 selects the last channel of each pixel.
    vImageOverwriteChannelsWithScalar_ARGB8888(
      0xFF, &dst, &dst, 0x1, vImage_Flags(kvImageNoFlags))
  }
}
