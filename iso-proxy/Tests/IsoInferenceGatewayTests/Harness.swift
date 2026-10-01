import Darwin
import Foundation
import IsoInferenceCore
import IsoInferenceGateway
import IsoProxyCore
import NIOPosix
import Synchronization
import Testing

/// A scripted loopback backend. Each accepted connection reads one request
/// (Content-Length framed), records it, then plays the script.
final class FakeBackend: Sendable {
  enum Script: Sendable {
    /// SSE events written with a pause between them, then close.
    case stream([String], pauseMilliseconds: Int = 0)
    /// SSE events, then hold the connection open until the client closes.
    case streamThenHang([String])
    /// A complete JSON response.
    case json(status: Int, body: String)
    /// Close without responding.
    case close
  }

  struct Recorded: Sendable {
    let head: String
    let body: [UInt8]
    var json: JSON? {
      try? JSONParser.parse(body, limits: .init(maxBytes: 1 << 24, maxDepth: 64))
    }
  }

  let port: UInt16
  private let fd: Int32
  private let script: Mutex<Script>
  private let recorded = Mutex<[Recorded]>([])
  private let finished = Mutex(0)
  private let closed = Mutex(false)

  init(_ script: Script) throws {
    self.script = Mutex(script)
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    _ = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    listen(listener, 16)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
    }
    fd = listener
    port = UInt16(bigEndian: address.sin_port)
    Thread { [weak self] in
      while true {
        let connection = accept(listener, nil, nil)
        guard connection >= 0, let self else { return }
        Thread { self.serve(connection) }.start()
      }
    }.start()
  }

  deinit {
    shutdown(fd, SHUT_RDWR)
    close(fd)
  }

  func setScript(_ new: Script) { script.withLock { $0 = new } }
  var requests: [Recorded] { recorded.withLock { $0 } }
  /// Connections whose script ran to completion (the backend "finished").
  var completed: Int { finished.withLock { $0 } }

  private func serve(_ connection: Int32) {
    defer { close(connection) }
    var one: Int32 = 1
    setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var buffer: [UInt8] = []
    var headEnd: Int?
    while headEnd == nil {
      var chunk = [UInt8](repeating: 0, count: 4096)
      let count = recv(connection, &chunk, chunk.count, 0)
      guard count > 0 else { return }
      buffer += chunk.prefix(count)
      if let range = findHeadEnd(buffer) { headEnd = range }
    }
    let head = String(decoding: buffer.prefix(headEnd!), as: UTF8.self)
    let length =
      head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
      .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
    var body = Array(buffer.dropFirst(headEnd! + 4))
    while body.count < length {
      var chunk = [UInt8](repeating: 0, count: 65536)
      let count = recv(connection, &chunk, chunk.count, 0)
      guard count > 0 else { return }
      body += chunk.prefix(count)
    }
    recorded.withLock { $0.append(Recorded(head: head, body: body)) }
    let current = script.withLock { $0 }
    switch current {
    case .stream(let events, let pause):
      guard send(connection, streamHead) else { return }
      for event in events {
        if pause > 0 { usleep(UInt32(pause) * 1000) }
        guard send(connection, chunked(event)) else { return }
      }
      guard send(connection, "0\r\n\r\n") else { return }
      finished.withLock { $0 += 1 }
    case .streamThenHang(let events):
      guard send(connection, streamHead) else { return }
      for event in events { guard send(connection, chunked(event)) else { return } }
      var byte: UInt8 = 0
      while recv(connection, &byte, 1, 0) > 0 {}
    case .json(let status, let text):
      let response =
        "HTTP/1.1 \(status) X\r\ncontent-type: application/json\r\ncontent-length: \(text.utf8.count)\r\nconnection: close\r\n\r\n\(text)"
      _ = send(connection, response)
      finished.withLock { $0 += 1 }
    case .close:
      return
    }
  }

  private let streamHead =
    "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n"

  private func chunked(_ event: String) -> String {
    let data = event + "\n\n"
    return String(data.utf8.count, radix: 16) + "\r\n" + data + "\r\n"
  }

  private func send(_ connection: Int32, _ text: String) -> Bool {
    let bytes = Array(text.utf8)
    var offset = 0
    while offset < bytes.count {
      let sent = bytes[offset...].withUnsafeBytes {
        Darwin.send(connection, $0.baseAddress, $0.count, 0)
      }
      guard sent > 0 else { return false }
      offset += sent
    }
    return true
  }
}

func findHeadEnd(_ bytes: [UInt8]) -> Int? {
  guard bytes.count >= 4 else { return nil }
  for index in 0...(bytes.count - 4)
  where bytes[index] == 13 && bytes[index + 1] == 10 && bytes[index + 2] == 13
    && bytes[index + 3] == 10
  {
    return index
  }
  return nil
}

/// A blocking HTTP/1.1 client for the session listener.
struct RawResponse {
  let status: Int
  let head: String
  let body: String
}

enum RawClient {
  /// A session socket, as the sandbox owner's relay connects to it.
  static func connect(_ path: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      let bytes = Array(path.utf8)
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    _ = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    var timeout = timeval(tv_sec: 20, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    return fd
  }

  static func sendAll(_ fd: Int32, _ bytes: [UInt8]) {
    var offset = 0
    while offset < bytes.count {
      let sent = bytes[offset...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
      guard sent > 0 else { return }
      offset += sent
    }
  }

  static func readAll(_ fd: Int32) -> RawResponse {
    var data: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
      let count = recv(fd, &chunk, chunk.count, 0)
      guard count > 0 else { break }
      data += chunk.prefix(count)
    }
    guard let end = findHeadEnd(data) else { return RawResponse(status: 0, head: "", body: "") }
    let head = String(decoding: data.prefix(end), as: UTF8.self)
    let status = Int(head.split(separator: " ").dropFirst().first ?? "") ?? 0
    var body = Array(data.dropFirst(end + 4))
    if head.lowercased().contains("transfer-encoding: chunked") { body = dechunk(body) }
    return RawResponse(status: status, head: head, body: String(decoding: body, as: UTF8.self))
  }

  static func dechunk(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    var index = 0
    while index < bytes.count {
      guard
        let lineEnd = (index..<(bytes.count - 1)).first(where: {
          bytes[$0] == 13 && bytes[$0 + 1] == 10
        })
      else { break }
      let size = Int(String(decoding: bytes[index..<lineEnd], as: UTF8.self), radix: 16) ?? 0
      if size == 0 { break }
      let start = lineEnd + 2
      out += bytes[start..<min(start + size, bytes.count)]
      index = start + size + 2
    }
    return out
  }

  static func request(
    socket: String, method: String = "POST", target: String, token: String?, body: String,
    extraHeaders: [(String, String)] = [], contentLength: Bool = true
  ) -> RawResponse {
    let fd = connect(socket)
    defer { close(fd) }
    var head = "\(method) \(target) HTTP/1.1\r\nhost: 127.0.0.1\r\n"
    if let token { head += "authorization: Bearer \(token)\r\n" }
    if method == "POST" { head += "content-type: application/json\r\n" }
    if contentLength && method == "POST" { head += "content-length: \(body.utf8.count)\r\n" }
    for (name, value) in extraHeaders { head += "\(name): \(value)\r\n" }
    head += "\r\n"
    sendAll(fd, Array((head + body).utf8))
    return readAll(fd)
  }
}

/// An in-process gateway with one registered, activated session.
final class Harness: @unchecked Sendable {
  let directory: String
  /// Short, so session socket paths fit `sun_path`.
  let relayDirectory: String
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
  let gateway: Gateway
  var transports: [Process] = []

  init(journalSeed: [UInt16: Int] = [:], backendPorts: Set<UInt16>? = nil) throws {
    signal(SIGPIPE, SIG_IGN)
    directory = NSTemporaryDirectory() + "iso-inference-test-" + UUID().uuidString
    try FileManager.default.createDirectory(
      atPath: directory + "/journal", withIntermediateDirectories: true)
    for (port, count) in journalSeed {
      try String(count).write(
        toFile: directory + "/journal/\(port).count", atomically: true, encoding: .utf8)
    }
    let journal = try Journal(directory: directory + "/journal")
    relayDirectory = "/tmp/ir-" + String(UUID().uuidString.prefix(8))
    try FileManager.default.createDirectory(
      atPath: relayDirectory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    gateway = Gateway(
      group: group, journal: journal, audit: AuditLog(path: directory + "/audit.log"),
      relayDirectory: relayDirectory, backendPorts: backendPorts, transportCommand: "sleep",
      onExit: {})
  }

  deinit {
    for process in transports where process.isRunning { process.terminate() }
    try? group.syncShutdownGracefully()
    try? FileManager.default.removeItem(atPath: directory)
    try? FileManager.default.removeItem(atPath: relayDirectory)
  }

  func spawnTransport() throws -> (Process, TransportBinding) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["300"]
    try process.run()
    transports.append(process)
    let identity = try #require(ProcessIdentity.of(process.processIdentifier))
    return (process, TransportBinding(pid: process.processIdentifier, start: identity.start))
  }

  struct Session {
    let id: String
    /// The session socket's path.
    let socket: String
    let token: String
    let transport: Process
  }

  func session(
    _ grants: [ServiceGrant], name: String = "dev", deadlineSeconds: Int64? = nil,
    activate: Bool = true
  ) throws -> Session {
    let registration = ControlProtocol.Registration(
      instance: .init(dataRoot: directory, name: name),
      boot: BootIdentity(ownerPID: 1, ownerStart: ProcessStart(seconds: 1, microseconds: 0)),
      nonce: String(repeating: "0", count: 32), limits: .defaults, grants: grants,
      socket: Self.socketName(name))
    let registered = try gateway.register(registration)
    let (process, binding) = try spawnTransport()
    if activate {
      try gateway.activate(
        ControlProtocol.Activation(
          sessionID: registered.sessionID, epoch: gateway.epoch, transport: binding,
          deadlineSeconds: deadlineSeconds))
    }
    return Session(
      id: registered.sessionID, socket: relayDirectory + "/" + registered.socket,
      token: registered.capability.expose(),
      transport: process)
  }

  /// The runtime names a socket by a hex hash; one per instance name here.
  static func socketName(_ instance: String) -> String {
    let hash = instance.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
      ($0 ^ UInt64($1)) &* 1_099_511_628_211
    }
    return String(hash, radix: 16) + ".sock"
  }

  func backend(_ port: UInt16) -> JSONObject? {
    gateway.inspect(nil)["backends"]?.array?.compactMap(\.object).first {
      $0["backend"]?.string == "127.0.0.1:\(port)"
    }
  }
}

func grant(
  _ backendProtocol: BackendProtocol, port: UInt16, apis: Set<FrontendAPI>? = nil,
  evidence: CompletionEvidence = .drain, maxActive: Int = 1, alias: String = "local-coder"
) -> ServiceGrant {
  let api: FrontendAPI =
    switch backendProtocol {
    case .openAIChat: .openAIChat
    case .openAIResponses: .openAIResponses
    case .anthropicMessages: .anthropicMessages
    }
  return ServiceGrant(
    alias: alias,
    backend: BackendPolicy(
      id: BackendID(port: port), name: "fake", maxActive: maxActive,
      profile: QualificationProfile(
        name: "fake-\(evidence.rawValue)", backendProtocol: backendProtocol, evidence: evidence,
        streamCloseDrainMilliseconds: 100, contextOverflow: .reject, overheadPerRequestBytes: 64,
        overheadPerMessageBytes: 8, maxInputBytes: 1 << 20, maxRequestBodyBytes: 4 << 20,
        tokenCounter: .none),
      credential: nil),
    upstreamModel: "real/model", apis: apis ?? [api], maxContextTokens: 32_768,
    defaultOutputTokens: 256, maxOutputTokens: 1_024, maxInputBytes: nil)
}

/// Poll until `condition` holds or the timeout passes.
func eventually(_ seconds: Double = 10, _ condition: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  while Date() < deadline {
    if condition() { return true }
    usleep(20_000)
  }
  return condition()
}

let chatEvents = [
  #"data: {"id":"c","model":"real/model","choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}]}"#,
  #"data: {"id":"c","model":"real/model","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
  #"data: {"id":"c","model":"real/model","choices":[],"usage":{"prompt_tokens":3,"completion_tokens":1}}"#,
  "data: [DONE]",
]

let chatBody =
  #"{"model":"local-coder","messages":[{"role":"user","content":"hello"}],"stream":true}"#
