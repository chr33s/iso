extension SeatbeltProfile {
  /// Confines the `iso-inference` broker (`Resources/seatbelt-inference.sb`,
  /// §5.1): writes only under `STATE_DIR`, reads only system files, the
  /// binary and that directory, no program execution except the initial exec
  /// of `INFERENCE_BIN`, and no network connection.
  static var inference: String { EmbeddedInference.gatewayProfile }

  static let backendPortsMarker = ";; @BACKEND_PORTS@"

  /// Confines one session's worker (`Resources/seatbelt-inference-worker.sb`,
  /// §5.1): only its `SESSION_SOCKET`, the broker's `BROKER_SOCKET` and the
  /// backend ports of the session's grants.
  static var inferenceWorkerTemplate: String { EmbeddedInference.workerProfile }

  /// One outbound rule per port in place of the marker; with no ports the
  /// worker can reach no backend.
  static func inferenceWorker(backendPorts: [UInt16]) -> String {
    let rules = Set(backendPorts).sorted().map {
      "(allow network-outbound (remote ip \"localhost:\($0)\"))"
    }
    return inferenceWorkerTemplate.replacingOccurrences(
      of: backendPortsMarker,
      with: rules.isEmpty ? ";; no backend ports" : rules.joined(separator: "\n"))
  }
}
