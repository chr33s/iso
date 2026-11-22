import IsoInferenceCore

/// Control-socket frames through the production parser and decoder. An
/// accepted request must re-encode and decode to the same operation.
public enum InferenceControlHarness {
  public static func run(_ bytes: [UInt8]) {
    guard let object = try? ControlProtocol.parseFrame(bytes),
      let request = try? ControlProtocol.decodeRequest(object)
    else { return }
    let again = try? ControlProtocol.decodeRequest(ControlProtocol.encode(request))
    require(again != nil, "an accepted control request round-trips")
    if case .register(let first) = request, case .register(let second)? = again {
      require(first.grants == second.grants, "grants round-trip")
      require(first.policyDigest == second.policyDigest, "the policy digest is stable")
    }
  }
}
