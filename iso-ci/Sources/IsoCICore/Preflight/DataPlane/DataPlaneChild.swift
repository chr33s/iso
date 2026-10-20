import Foundation
import NIOPosix

/// The confined child invocation of the iso-ci executable that serves the
/// scoped preflight endpoint (`iso-ci _dataplane --sockets <dir> --staging
/// <dir>`). It is started by `DataPlaneSupervisor` under the Seatbelt
/// profile with an empty environment and only stdin/stdout/stderr open; its
/// only link to the controller is the bounded frame channel on stdin/stdout.
/// It binds one Unix socket per registered allocation inside the sockets
/// directory and reports the socket's name in the registration reply.
package enum DataPlaneChild {
  /// Serves until the controller closes the channel or sends `shutdown`.
  package static func run(socketDirectory: String, stagingDirectory: String) async throws(CIError) {
    let channel = DataPlaneChannel(input: 0, output: 1)
    let pending = DataPlanePendingCalls()
    let backend = ChannelBackend(channel: channel, pending: pending)
    let service = try DataPlaneService(backend: backend, staging: stagingDirectory)
    let sockets = AllocationSockets(directory: socketDirectory, service: service)
    let (closed, closedContinuation) = AsyncStream.makeStream(of: CIError?.self)
    channel.startReading(
      onFrame: { frame in
        switch frame {
        case .register(let id, let grant):
          Task {
            let result: Result<JSONValue, CIError>
            do throws(CIError) {
              try await service.register(grant)
              do throws(CIError) {
                let name = try await sockets.open(grant.allocation)
                result = .success(["socket": .string(name)])
              } catch {
                await service.unregister(grant.allocation)
                throw error
              }
            } catch {
              result = .failure(error)
            }
            try? channel.send(.reply(id: id, result: result))
          }
        case .unregister(let allocation):
          Task {
            await sockets.close(allocation)
            await service.unregister(allocation)
          }
        case .cancel(let allocation):
          Task { await service.cancel(allocation) }
        case .reply(let id, let result):
          pending.resolve(id, result)
        case .shutdown:
          closedContinuation.yield(nil)
        case .ready, .request, .event:
          // Only the controller may send these to the child.
          closedContinuation.yield(CIError.invalid("unexpected frame from the controller"))
        }
      },
      onClose: { error in closedContinuation.yield(error) })
    try channel.send(.ready)
    var reason: CIError?
    for await event in closed {
      reason = event
      break
    }
    pending.close(CIError(.controllerUnavailable, "the controller channel closed"))
    await sockets.closeAll()
    if let reason { throw reason }
  }

  /// `--jail-selftest`: proves, from inside the sandbox, that confinement
  /// holds — the probe path (a controller-private file) is unreadable, a
  /// loopback TCP connection is refused, writing outside the staging
  /// directory fails — and, as a positive control, that the staging
  /// directory is writable. Prints one JSON line; true only if all hold.
  package static func selfTest(stagingDirectory: String, probePath: String, tcpPort: UInt16) -> (
    Bool, JSONValue
  ) {
    var checks: [String: JSONValue] = [:]
    // Positive control: the staging directory is usable.
    let control = stagingDirectory + "/selftest-" + randomHex(bytes: 4)
    let fd = open(control, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    checks["staging_writable"] = .bool(fd >= 0)
    if fd >= 0 {
      close(fd)
      unlink(control)
    }
    // The controller-private probe must not be readable.
    let probe = open(probePath, O_RDONLY)
    checks["probe_denied"] = .bool(probe < 0)
    if probe >= 0 { close(probe) }
    // No write outside staging.
    let outside =
      (probePath as NSString).deletingLastPathComponent + "/.iso-ci-jail-probe-"
      + randomHex(bytes: 4)
    let outsideFD = open(outside, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    checks["outside_write_denied"] = .bool(outsideFD < 0)
    if outsideFD >= 0 {
      close(outsideFD)
      unlink(outside)
    }
    // No symlinks (the unconfined controller and the guest forward must
    // never be redirected) and no hard links to files outside staging.
    let link = stagingDirectory + "/selftest-link-" + randomHex(bytes: 4)
    checks["symlink_denied"] = .bool(symlink("/", link) != 0)
    unlink(link)
    checks["hardlink_denied"] = .bool(Darwin.link(probePath, link) != 0)
    unlink(link)
    // No outbound TCP, even to loopback.
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    var denied = true
    if socketFD >= 0 {
      var address = sockaddr_in()
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = tcpPort.bigEndian
      address.sin_addr.s_addr = inet_addr("127.0.0.1")
      let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      // EPERM/EACCES is the sandbox; ECONNREFUSED would mean the connect
      // was allowed and only found no listener — that is a failure.
      denied = result != 0 && (errno == EPERM || errno == EACCES)
      close(socketFD)
    }
    checks["tcp_denied"] = .bool(denied)
    // No process execution.
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
    defer { free(argv[0]) }
    let spawned = posix_spawn(&pid, "/usr/bin/true", nil, nil, argv, nil)
    if spawned == 0 {
      var status: Int32 = 0
      waitpid(pid, &status, 0)
    }
    checks["exec_denied"] = .bool(spawned != 0)
    let confined = checks.values.allSatisfy { $0 == .bool(true) }
    return (confined, ["confined": .bool(confined), "checks": .object(checks)])
  }
}

/// The child's backend: every call becomes a request frame the controller
/// authorizes and answers.
final class ChannelBackend: DataPlaneBackend {
  let channel: DataPlaneChannel
  let pending: DataPlanePendingCalls

  init(channel: DataPlaneChannel, pending: DataPlanePendingCalls) {
    self.channel = channel
    self.pending = pending
  }

  func call(_ allocation: AllocationID, _ call: DataPlaneCall) async throws(CIError) -> JSONValue {
    try await pending.call { (id) throws(CIError) in
      try channel.send(.request(id: id, allocation: allocation, call: call))
    }
  }

  func event(_ allocation: AllocationID, _ event: DataPlaneEvent) async {
    try? channel.send(.event(allocation: allocation, event))
  }
}

extension DataPlaneChild {
  /// The `_dataplane` entrypoint: `--sockets <dir> --staging <dir>` serves;
  /// `--jail-selftest --staging <dir> --probe <path> --tcp-port <n>` prints
  /// the confinement report. Returns the process exit status.
  package static func main(arguments: [String]) async -> Int32 {
    var options: [String: String] = [:]
    var selfTestMode = false
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      if argument == "--jail-selftest" {
        selfTestMode = true
        index += 1
        continue
      }
      guard ["--sockets", "--staging", "--probe", "--tcp-port"].contains(argument),
        index + 1 < arguments.count
      else { return 64 }
      options[argument] = arguments[index + 1]
      index += 2
    }
    guard let staging = options["--staging"] else { return 64 }
    if selfTestMode {
      guard let probe = options["--probe"], let port = options["--tcp-port"].flatMap(UInt16.init)
      else {
        return 64
      }
      let (confined, report) = selfTest(stagingDirectory: staging, probePath: probe, tcpPort: port)
      FileHandle.standardOutput.write(Data(report.frame))
      return confined ? 0 : 3
    }
    guard let sockets = options["--sockets"] else { return 64 }
    do throws(CIError) {
      try await run(socketDirectory: sockets, stagingDirectory: staging)
      return 0
    } catch {
      FileHandle.standardError.write(Data("iso-ci data plane: \(error.description)\n".utf8))
      return 1
    }
  }
}

/// One endpoint socket per allocation, all served from one event loop group.
actor AllocationSockets {
  private let directory: String
  private let service: DataPlaneService
  private let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
  private var servers: [AllocationID: DataPlaneHTTPServer] = [:]
  package static let maxSockets = 128

  init(directory: String, service: DataPlaneService) {
    self.directory = directory
    self.service = service
  }

  /// Binds a fresh socket for `allocation`; returns its 16-hex name.
  func open(_ allocation: AllocationID) async throws(CIError) -> String {
    guard servers[allocation] == nil else {
      throw CIError(.conflict, "allocation already has a socket")
    }
    guard servers.count < Self.maxSockets else {
      throw CIError(.budgetExceeded, "too many endpoint sockets")
    }
    let name = randomHex(bytes: 8)
    let server = try await DataPlaneHTTPServer.start(
      socketPath: directory + "/" + name, service: service, allocation: allocation, group: group)
    servers[allocation] = server
    return name
  }

  func close(_ allocation: AllocationID) async {
    await servers.removeValue(forKey: allocation)?.close()
  }

  func closeAll() async {
    for server in servers.values { await server.close() }
    servers = [:]
    try? await group.shutdownGracefully()
  }
}
