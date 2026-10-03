import CryptoKit
import Darwin
import Foundation
import IsoCore

/// Fresh, authenticated responses from the companion, directly and through
/// the guest loopback transport. No reply or proof is persisted.
enum FilteredReadiness {
  static func keyPath(_ instance: Instance) -> String {
    instance.directory + "/egress-readiness-public-key"
  }

  struct VerificationKey: Sendable {
    let value: Curve25519.Signing.PublicKey
    var encoded: String { value.rawRepresentation.map { String(format: "%02x", $0) }.joined() }

    fileprivate init(_ value: Curve25519.Signing.PublicKey) { self.value = value }

    init(encoded: String) throws(HostError) {
      guard let bytes = FilteredReadiness.hex(encoded, count: 32),
        let value = try? Curve25519.Signing.PublicKey(rawRepresentation: bytes)
      else { throw HostError("FILTERED_EGRESS_NOT_READY: invalid readiness verification key") }
      self.value = value
    }
  }

  /// Only the public half can be persisted. The private seed goes transiently
  /// to companion startup stdin and is never written to workspace-visible state.
  struct SigningIdentity: Sendable {
    private let privateKey: Curve25519.Signing.PrivateKey

    init() { privateKey = Curve25519.Signing.PrivateKey() }
    init(seed: Data) throws {
      privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    var startupKey: Secret<String> {
      Secret(privateKey.rawRepresentation.map { String(format: "%02x", $0) }.joined())
    }
    var verificationKey: VerificationKey { VerificationKey(privateKey.publicKey) }

    func persistVerificationKey(_ instance: Instance) throws {
      try AtomicFile.write(
        Array(verificationKey.encoded.utf8), to: FilteredReadiness.keyPath(instance),
        mode: .atMost(0o600))
    }
  }

  static func hex(_ text: String, count: Int) -> [UInt8]? {
    let bytes = Array(text.utf8)
    guard bytes.count == count * 2 else { return nil }
    func nibble(_ byte: UInt8) -> UInt8? {
      switch byte {
      case 48...57: byte - 48
      case 97...102: byte - 87
      default: nil
      }
    }
    var decoded: [UInt8] = []
    for index in stride(from: 0, to: bytes.count, by: 2) {
      guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
      decoded.append(high * 16 + low)
    }
    return decoded
  }

  static func request(nonce: String, capability: Secret<String>) -> [UInt8] {
    let basic = Data("iso:\(capability.expose())".utf8).base64EncodedString()
    return Array(
      ("GET /__iso/egress-ready HTTP/1.1\r\nProxy-Authorization: Basic \(basic)\r\nX-Iso-Nonce: \(nonce)\r\n\r\n")
        .utf8)
  }

  private struct Reply: Decodable {
    let version: Int
    let nonce: String
    let bootID: String
    let policyHash: String
    let signature: String
  }

  static func verifies(
    _ response: [UInt8], nonce: String, policy: FilteredHandoff.BootPolicy, key: VerificationKey
  ) -> Bool {
    guard response.count <= 1024,
      let text = String(bytes: response, encoding: .utf8),
      let split = text.range(of: "\r\n\r\n")
    else { return false }
    let headers = text[..<split.lowerBound].components(separatedBy: "\r\n")
    let body = Data(text[split.upperBound...].utf8)
    guard headers.count == 3, headers[0] == "HTTP/1.1 200 OK",
      headers[1] == "Content-Length: \(body.count)", headers[2] == "Connection: close",
      let reply = try? JSONDecoder().decode(Reply.self, from: body),
      reply.version == 2, reply.nonce == nonce,
      reply.bootID == policy.bootID, reply.policyHash == policy.policyHash,
      let signature = Data(base64Encoded: reply.signature), signature.count == 64
    else { return false }
    let message = "iso-egress-readiness-v2\n\(reply.nonce)\n\(reply.bootID)\n\(reply.policyHash)\n"
    return key.value.isValidSignature(signature, for: Data(message.utf8))
  }

  @discardableResult
  static func require(
    _ instance: Instance, target: SSHTarget, environment: [String: String],
    policy: FilteredHandoff.BootPolicy
  ) throws -> VerificationKey {
    let key = try readVerificationKey(at: keyPath(instance))
    let capability = try readIdentity(at: EgressPorts.capabilityPath(instance))
    let port = EgressPorts.port(instance)
    let directNonce = randomHex(16)
    guard
      let direct = exchange(
        port: port, request: request(nonce: directNonce, capability: capability)),
      verifies(direct, nonce: directNonce, policy: policy, key: key)
    else { throw HostError("FILTERED_EGRESS_NOT_READY: authenticated companion probe failed") }
    let guestNonce = randomHex(16)
    let output: ProcessRunner.Output
    do {
      output = try ProcessRunner().capture(
        guestRequest(
          target, client: SSHClient(environment: environment), port: port,
          nonce: guestNonce, capability: capability))
    } catch {
      throw ContextError(
        "FILTERED_EGRESS_NOT_READY: guest-loopback probe did not complete", cause: error)
    }
    guard output.termination.succeeded else {
      throw HostError(
        "FILTERED_EGRESS_NOT_READY: guest-loopback probe exited with \(output.termination)")
    }
    guard verifies(output.stdout, nonce: guestNonce, policy: policy, key: key) else {
      throw HostError("FILTERED_EGRESS_NOT_READY: authenticated guest-loopback probe failed")
    }
    return key
  }

  static func guestRequest(
    _ target: SSHTarget, client: SSHClient, port: UInt16, nonce: String, capability: Secret<String>
  ) throws -> ProcessRunner.Request {
    try guestExchangeRequest(
      target, client: client, port: port, request: request(nonce: nonce, capability: capability))
  }

  static func guestExchangeRequest(
    _ target: SSHTarget, client: SSHClient, port: UInt16, request: [UInt8]
  ) throws -> ProcessRunner.Request {
    let command = RemoteCommand().literal("/usr/bin/timeout 2 /bin/bash -c ").arg(guestProbe)
    let input = Array("\(port)\n".utf8) + request
    return .init(
      executable: try client.ssh(),
      arguments: target.sshOptions + [target.address, command.rendered],
      environment: client.environment, deadline: .seconds(5), outputLimit: 1024,
      input: input)
  }

  static func readVerificationKey(at path: String) throws(HostError) -> VerificationKey {
    try VerificationKey(encoded: readIdentity(at: path).expose())
  }

  static func readIdentity(at path: String) throws(HostError) -> Secret<String> {
    guard let bytes = try StateStore.readControlFile(path) else {
      throw HostError("FILTERED_EGRESS_NOT_READY: missing readiness identity; restart the instance")
    }
    guard let text = String(bytes: bytes, encoding: .utf8), hex(text, count: 32) != nil else {
      throw HostError("FILTERED_EGRESS_NOT_READY: invalid readiness identity; restart the instance")
    }
    return Secret(text)
  }

  // Only a public challenge and the already guest-visible capability go to
  // the guest. Untrusted stdout is authenticated, never executed or logged.
  static let guestProbe = """
    set -e
    IFS= read -r port
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || exit 1
    exec 3<>/dev/tcp/127.0.0.1/"$port"
    /usr/bin/cat >&3
    /usr/bin/head -c 1025 <&3
    """

  static func exchange(port: UInt16, request: [UInt8]) -> [UInt8]? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    let flags = fcntl(fd, F_GETFL)
    var noSignal: Int32 = 1
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0
    else { return nil }
    let deadline = ContinuousClock.now + .seconds(2)
    func wait(_ events: Int16) -> Bool {
      while ContinuousClock.now < deadline {
        var event = pollfd(fd: fd, events: events, revents: 0)
        let result = poll(&event, 1, 20)
        if result > 0 { return event.revents & Int16(POLLNVAL) == 0 }
        if result < 0 && errno != EINTR { return false }
      }
      return false
    }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if connected != 0 {
      guard errno == EINPROGRESS, wait(Int16(POLLOUT)) else { return nil }
      var error: Int32 = 0
      var length = socklen_t(MemoryLayout<Int32>.size)
      guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
        return nil
      }
    }
    var offset = 0
    while offset < request.count {
      guard wait(Int16(POLLOUT)) else { return nil }
      let sent = request.withUnsafeBytes { buffer -> Int in
        guard let base = buffer.baseAddress else { return 0 }
        return send(fd, base.advanced(by: offset), request.count - offset, 0)
      }
      if sent > 0 {
        offset += sent
        continue
      }
      if sent < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
      return nil
    }
    var response: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 1025)
    while wait(Int16(POLLIN)) {
      let count = recv(fd, &buffer, buffer.count, 0)
      if count == 0 { return response }
      if count < 0 {
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
        return nil
      }
      response.append(contentsOf: buffer.prefix(count))
      if response.count > 1024 { return nil }
    }
    return nil
  }
}
