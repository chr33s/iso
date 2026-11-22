extension SeatbeltProfile {
  /// Confines `iso-inference` (`Resources/seatbelt-inference.sb`). Writes only
  /// under `STATE_DIR` and `RELAY_DIR`, reads only system files, the binary
  /// and those directories, no program execution except the initial exec of
  /// `INFERENCE_BIN`, and outbound connections only to the backend ports
  /// `inference(backendPorts:)` renders in place of the marker.
  static var inferenceTemplate: String { EmbeddedInference.gatewayProfile }

  static let backendPortsMarker = ";; @BACKEND_PORTS@"

  /// The profile for one gateway launch. Each port gets one outbound rule;
  /// with no ports the gateway can reach no backend.
  static func inference(backendPorts: [UInt16]) -> String {
    let rules = backendPorts.sorted().map {
      "(allow network-outbound (remote ip \"localhost:\($0)\"))"
    }
    return inferenceTemplate.replacingOccurrences(
      of: backendPortsMarker,
      with: rules.isEmpty ? ";; no backend ports" : rules.joined(separator: "\n"))
  }
}
