import Accelerate
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// One H.264 stream of the display (docs/design/computer-use-live-view.md §4):
/// Constrained Baseline, automatic level, real time, no frame reordering, on the
/// hardware encoder.
/// Frames come from the owner's own render, never guest-authored bytes.
package final class LiveViewEncoder: @unchecked Sendable {
  package typealias Output =
    @Sendable (_ annexB: [UInt8], _ keyframe: Bool, _ micros: UInt64) -> Void

  private let session: VTCompressionSession
  private let width: Int
  private let height: Int
  private let output: Output
  private let start = ContinuousClock.now

  package init(width: Int, height: Int, output: @escaping Output) throws {
    self.width = width
    self.height = height
    self.output = output
    var made: VTCompressionSession?
    let spec: [CFString: Any] = [
      kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
    ]
    let buffers: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
    ]
    let status = VTCompressionSessionCreate(
      allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
      encoderSpecification: spec as CFDictionary, imageBufferAttributes: buffers as CFDictionary,
      compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &made)
    guard status == noErr, let made else {
      throw SandboxError("no hardware H.264 encoder (VideoToolbox status \(status))")
    }
    session = made
    let properties: [CFString: Any] = [
      kVTCompressionPropertyKey_RealTime: true,
      kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel,
      kVTCompressionPropertyKey_AllowFrameReordering: false,
      kVTCompressionPropertyKey_ExpectedFrameRate: LiveView.frameRateCap,
      // Keyframes are forced on join and after a drop; a long interval
      // otherwise keeps a static screen cheap.
      kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 60,
    ]
    for (key, value) in properties {
      VTSessionSetProperty(made, key: key, value: value as CFTypeRef)
    }
    VTCompressionSessionPrepareToEncodeFrames(made)
  }

  deinit { invalidate() }

  package func invalidate() {
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    VTCompressionSessionInvalidate(session)
  }

  /// Encodes one RGBX render (rows packed, `width * 4` bytes each).
  package func encode(rgbx: UnsafeRawPointer, bytesPerRow: Int, keyframe: Bool) throws {
    guard let pool = VTCompressionSessionGetPixelBufferPool(session) else {
      throw SandboxError("no pixel buffer pool")
    }
    var made: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess,
      let buffer = made
    else { throw SandboxError("no pixel buffer") }
    CVPixelBufferLockBaseAddress(buffer, [])
    var src = vImage_Buffer(
      data: UnsafeMutableRawPointer(mutating: rgbx), height: vImagePixelCount(height),
      width: vImagePixelCount(width), rowBytes: bytesPerRow)
    var dst = vImage_Buffer(
      data: CVPixelBufferGetBaseAddress(buffer), height: vImagePixelCount(height),
      width: vImagePixelCount(width), rowBytes: CVPixelBufferGetBytesPerRow(buffer))
    // RGBX to BGRX.
    let permuted = vImagePermuteChannels_ARGB8888(
      &src, &dst, [2, 1, 0, 3], vImage_Flags(kvImageNoFlags))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    guard permuted == kvImageNoError else { throw SandboxError("pixel conversion failed") }
    let elapsed = (ContinuousClock.now - start).components
    let micros =
      UInt64(elapsed.seconds) * 1_000_000 + UInt64(elapsed.attoseconds / 1_000_000_000_000)
    let pts = CMTime(value: CMTimeValue(micros), timescale: 1_000_000)
    let options: CFDictionary? =
      keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
    let output = output
    let status = VTCompressionSessionEncodeFrame(
      session, imageBuffer: buffer, presentationTimeStamp: pts, duration: .invalid,
      frameProperties: options, infoFlagsOut: nil
    ) { status, _, sample in
      guard status == noErr, let sample, let (bytes, key) = Self.annexB(sample) else { return }
      output(bytes, key, micros)
    }
    guard status == noErr else { throw SandboxError("encode failed (status \(status))") }
  }

  /// A compressed sample as Annex-B, with its parameter sets when it is a
  /// keyframe.
  static func annexB(_ sample: CMSampleBuffer) -> ([UInt8], Bool)? {
    guard let block = CMSampleBufferGetDataBuffer(sample),
      let format = CMSampleBufferGetFormatDescription(sample)
    else { return nil }
    let attachments =
      CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
      as? [[CFString: Any]]
    let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    var count = 0
    var lengthSize: Int32 = 4
    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
      format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
      parameterSetCountOut: &count, nalUnitHeaderLengthOut: &lengthSize)
    var sets: [[UInt8]] = []
    if keyframe {
      for i in 0..<count {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        guard
          CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: i, parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size, parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil) == noErr, let pointer
        else { return nil }
        // The SPS gains a low-delay VUI; the PPS passes through unchanged.
        let set = Array(UnsafeBufferPointer(start: pointer, count: size))
        sets.append(LiveViewSPS.withLowDelay(set))
      }
    }
    var length = 0
    var data: UnsafeMutablePointer<CChar>?
    guard
      CMBlockBufferGetDataPointer(
        block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
        dataPointerOut: &data) == noErr, let data
    else { return nil }
    let avcc = UnsafeRawBufferPointer(start: data, count: length)
    guard let out = annexB(avcc: Array(avcc), lengthSize: Int(lengthSize), parameterSets: sets)
    else { return nil }
    return (out, keyframe)
  }

  private static let startCode: [UInt8] = [0, 0, 0, 1]

  /// Length-prefixed NAL units to start-code-prefixed ones, parameter sets
  /// first; nil when a length runs past the end.
  package static func annexB(avcc: [UInt8], lengthSize: Int, parameterSets: [[UInt8]])
    -> [UInt8]?
  {
    guard (1...4).contains(lengthSize) else { return nil }
    var out: [UInt8] = []
    out.reserveCapacity(avcc.count + parameterSets.reduce(0) { $0 + $1.count + 4 } + 16)
    for set in parameterSets { out += startCode + set }
    var i = 0
    while i < avcc.count {
      guard avcc.count - i >= lengthSize else { return nil }
      var n = 0
      for b in avcc[i..<i + lengthSize] { n = n << 8 | Int(b) }
      i += lengthSize
      guard n > 0, avcc.count - i >= n else { return nil }
      out += startCode
      out += avcc[i..<i + n]
      i += n
    }
    return out
  }
}
