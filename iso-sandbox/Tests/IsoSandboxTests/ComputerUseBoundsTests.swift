import Foundation
import IOSurface
import IsoMacProtocol
import Testing

@testable import IsoSandboxCore

// Bounds on what the guest and a viewer can make the owner do: parser
// depth, interrupted key sequences, and the framebuffer copy.

@Test func aGuestRequestNestedPastItsDeepestFormIsRefusedUnparsed() {
  // The deepest request there is: a drag's path of points.
  let drag = Array(
    #"{"op":"act","session":"s","basedOnFrame":"f","action":{"kind":"drag","path":[{"x":1,"y":2},{"x":3,"y":4}]}}"#
      .utf8)
  #expect(!JSONNesting.exceeds(drag, limit: GuestCUProtocol.maxNesting))
  guard case .success(let request) = GuestCURequest.parse(drag) else {
    Issue.record("the deepest request did not parse")
    return
  }
  #expect(request.action?.path?.count == 2)
  // One level more, in a field the closed set allows.
  let deeper = Array(#"{"op":"act","action":{"path":[{"x":{"a":1}}]}}"#.utf8)
  #expect(GuestCURequest.parse(deeper) == .failure(.tooDeep))
  // What overflowed a connection thread's stack in `JSONSerialization`.
  let nested = Array(String(repeating: #"{"a":"#, count: 800).utf8)
  #expect(nested.count <= GuestCUProtocol.maxRequest)
  #expect(GuestCURequest.parse(nested) == .failure(.tooDeep))
  #expect(GuestCURequest.ParseError.tooDeep.kind == "nested too deep")
}

@Test func aGuestLineNestedTooDeepIsAnsweredAndTheLinkGoesOn() {
  let quiet: @Sendable (String) -> Void = { _ in }
  let link = MacGuestCULink(frameRate: 4, log: quiet) { _ in GuestCUResponse(ok: true) }
  let nested = Array(String(repeating: #"{"a":"#, count: 800).utf8)
  let refused = link.respond(to: nested)
  #expect(!refused.ok && refused.refusal == .invalidAction && refused.beforeInput == true)
  #expect(link.respond(to: Array(#"{"op":"status"}"#.utf8)).ok)
}

@MainActor
@Test func aKeySequenceCutShortReleasesWhatItPressed() async throws {
  struct Ended: Error {}
  let keys = CUKeys.events(forText: "Ab")
  var sent: [CUKeyEvent] = []
  // Delivered whole when nothing interrupts.
  try await CUKeys.deliver(keys, send: { sent.append($0) }, pause: {})
  #expect(sent == keys)
  // A pause that throws (a paste whose viewer lost control, an action
  // whose session broke) stops there and lets go of what is down.
  sent = []
  var pauses = 0
  await #expect(throws: Ended.self) {
    try await CUKeys.deliver(
      keys, send: { sent.append($0) },
      pause: {
        pauses += 1
        if pauses == 2 { throw Ended() }
      })
  }
  #expect(pauses == 2)
  #expect(Array(sent.prefix(2)) == Array(keys.prefix(2)))
  #expect(Array(sent.dropFirst(2)) == CUKeys.releases(after: keys.prefix(2)))
  #expect(sent.count < keys.count + CUKeys.releases(after: keys.prefix(2)).count)
  #expect(!CUKeys.releases(after: keys.prefix(2)).isEmpty)
}

private func surface(width: Int, height: Int, format: OSType) -> IOSurfaceRef? {
  IOSurfaceCreate(
    [
      kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfaceBytesPerElement: 4,
      kIOSurfacePixelFormat: format,
    ] as CFDictionary)
}

@Test func aFramebufferOfAnotherSizeOrFormatIsNeverCopied() throws {
  let width = 16
  let height = 8
  let bytes = width * height * 4
  let destination = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
  defer { destination.deallocate() }
  let pixels = UnsafeMutableRawBufferPointer(start: destination, count: bytes)
  pixels.initializeMemory(as: UInt8.self, repeating: 0xAA)
  func read(_ s: IOSurfaceRef) throws(FramebufferSurface.Failure) {
    try FramebufferSurface.read(
      s, width: width, height: height, into: destination, bytesPerRow: width * 4)
  }
  // The expected surface is copied: alpha forced opaque.
  let good = try #require(
    surface(width: width, height: height, format: FramebufferSurface.pixelFormat))
  try read(good)
  #expect(pixels[3] == 0xFF && pixels[0] == 0)
  // A larger one would overrun the fixed-size destination; a smaller one
  // would leave stale rows. Neither is read.
  pixels.initializeMemory(as: UInt8.self, repeating: 0xAA)
  let wide = try #require(
    surface(width: width * 2, height: height, format: FramebufferSurface.pixelFormat))
  #expect(throws: FramebufferSurface.Failure.geometry(width: width * 2, height: height)) {
    try read(wide)
  }
  let tall = try #require(
    surface(width: width, height: height * 2, format: FramebufferSurface.pixelFormat))
  #expect(throws: FramebufferSurface.Failure.geometry(width: width, height: height * 2)) {
    try read(tall)
  }
  let other: OSType = 0x3432_3076  // '420v'
  let foreign = try #require(surface(width: width, height: height, format: other))
  #expect(throws: FramebufferSurface.Failure.format(other)) { try read(foreign) }
  #expect(pixels.allSatisfy { $0 == 0xAA })
}
