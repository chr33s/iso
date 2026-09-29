import IsoFuzzHarnesses

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOne(_ data: UnsafePointer<UInt8>?, _ size: Int) -> CInt {
  ParseRepoSlugHarness.run(size == 0 ? [] : Array(UnsafeBufferPointer(start: data, count: size)))
  return 0
}
