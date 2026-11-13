/// Makes an H.264 SPS say the stream is low delay. VideoToolbox writes an
/// SPS without VUI, so a decoder must assume frames may be reordered and
/// holds up to a full decoded-picture buffer (about 12 frames at 1920×1200,
/// level 5.0) before showing anything. Chrome's and Safari's hardware
/// decoders do, which leaves a static screen blank. Appending a VUI whose
/// bitstream restriction says `max_num_reorder_frames = 0` and
/// `max_dec_frame_buffering = max_num_ref_frames` lets them output each
/// frame as it arrives. Pure, so it is unit-testable.
package enum LiveViewSPS {
  /// `nal` is one SPS NAL unit with its header byte and no start code.
  /// An SPS that already has VUI, carries scaling matrices, or does not parse is returned
  /// unchanged.
  package static func withLowDelay(_ nal: [UInt8]) -> [UInt8] {
    guard nal.count > 4, nal[0] & 0x1F == 7 else { return nal }
    let rbsp = unescape(Array(nal.dropFirst()))
    var r = BitReader(rbsp)
    var w = BitWriter()
    guard let profile = r.bits(8), let rest = r.bits(16) else { return nal }
    w.put(profile, 8)
    w.put(rest, 16)
    func ue() -> UInt32? {
      guard let v = r.ue() else { return nil }
      w.ue(v)
      return v
    }
    func bit() -> UInt32? {
      guard let v = r.bits(1) else { return nil }
      w.put(v, 1)
      return v
    }
    func se() -> Bool { ue() != nil }
    guard ue() != nil else { return nal }  // seq_parameter_set_id
    if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
      guard let chroma = ue() else { return nal }
      if chroma == 3 { guard bit() != nil else { return nal } }
      guard ue() != nil, ue() != nil, bit() != nil else { return nal }
      // seq_scaling_matrix_present_flag: matrices are not rewritten.
      guard let scaling = bit(), scaling == 0 else { return nal }
    }
    guard ue() != nil, let pocType = ue() else { return nal }
    switch pocType {
    case 0:
      guard ue() != nil else { return nal }
    case 1:
      guard bit() != nil, se(), se(), let cycle = ue(), cycle < 256 else { return nal }
      for _ in 0..<cycle { guard se() else { return nal } }
    default: break
    }
    guard let refFrames = ue(), bit() != nil, ue() != nil, ue() != nil,
      let frameMbsOnly = bit()
    else { return nal }
    if frameMbsOnly == 0 { guard bit() != nil else { return nal } }
    guard bit() != nil, let cropping = bit() else { return nal }
    if cropping == 1 {
      for _ in 0..<4 { guard ue() != nil else { return nal } }
    }
    guard let vui = r.bits(1), vui == 0 else { return nal }
    w.put(1, 1)  // vui_parameters_present_flag
    // aspect ratio, overscan, video signal, chroma location, timing, NAL
    // HRD, VCL HRD and pic_struct: absent.
    w.put(0, 8)
    w.put(1, 1)  // bitstream_restriction_flag
    w.put(1, 1)  // motion_vectors_over_pic_boundaries_flag
    w.ue(2)  // max_bytes_per_pic_denom
    w.ue(1)  // max_bits_per_mb_denom
    w.ue(16)  // log2_max_mv_length_horizontal
    w.ue(16)  // log2_max_mv_length_vertical
    w.ue(0)  // max_num_reorder_frames
    w.ue(max(1, refFrames))  // max_dec_frame_buffering
    w.trailing()
    return [nal[0]] + escape(w.bytes)
  }

  /// Removes emulation-prevention bytes (`00 00 03` to `00 00`).
  static func unescape(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    var zeros = 0
    for b in bytes {
      if zeros >= 2 && b == 3 {
        zeros = 0
        continue
      }
      out.append(b)
      zeros = b == 0 ? zeros + 1 : 0
    }
    return out
  }

  /// Adds emulation-prevention bytes where `00 00` precedes 0–3.
  static func escape(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    var zeros = 0
    for b in bytes {
      if zeros >= 2 && b <= 3 {
        out.append(3)
        zeros = 0
      }
      out.append(b)
      zeros = b == 0 ? zeros + 1 : 0
    }
    return out
  }

  struct BitReader {
    let bytes: [UInt8]
    var position = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func bits(_ n: Int) -> UInt32? {
      var v: UInt32 = 0
      for _ in 0..<n {
        guard position / 8 < bytes.count else { return nil }
        let bit = (bytes[position / 8] >> (7 - UInt8(position % 8))) & 1
        v = v << 1 | UInt32(bit)
        position += 1
      }
      return v
    }

    mutating func ue() -> UInt32? {
      var zeros = 0
      while true {
        guard let b = bits(1) else { return nil }
        if b == 1 { break }
        zeros += 1
        guard zeros < 32 else { return nil }
      }
      guard let suffix = bits(zeros) else { return nil }
      return (UInt32(1) << zeros) - 1 + suffix
    }
  }

  struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var used = 8

    mutating func put(_ value: UInt32, _ n: Int) {
      for i in stride(from: n - 1, through: 0, by: -1) {
        if used == 8 {
          bytes.append(0)
          used = 0
        }
        bytes[bytes.count - 1] |= UInt8((value >> UInt32(i)) & 1) << (7 - UInt8(used))
        used += 1
      }
    }

    mutating func ue(_ value: UInt32) {
      let v = UInt64(value) + 1
      let length = 64 - v.leadingZeroBitCount
      put(0, length - 1)
      for i in stride(from: length - 1, through: 0, by: -1) { put(UInt32((v >> UInt64(i)) & 1), 1) }
    }

    /// rbsp_stop_one_bit and alignment zeros.
    mutating func trailing() {
      put(1, 1)
      while used != 8 { put(0, 1) }
    }
  }
}
