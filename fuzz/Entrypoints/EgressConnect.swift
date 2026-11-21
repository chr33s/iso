import IsoEgressFuzzHarnesses

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOne(_ data: UnsafePointer<UInt8>?, _ size: Int) -> CInt {
  EgressConnectHarness.run(size == 0 ? [] : Array(UnsafeBufferPointer(start: data, count: size)))
  return 0
}
