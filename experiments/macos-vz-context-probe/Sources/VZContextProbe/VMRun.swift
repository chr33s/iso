import Darwin
import Foundation
import Virtualization

/// `vm-run`: Phase 1/2 headless owner, following the no-view procedure of spec
/// §9. No AppKit, no VZVirtualMachineView, no WindowServer connection.
///
/// Per cycle: configure → validate → `VMHost` (VM on its serial queue) → start
/// → running → guest helper hello (vsock) and SSH banner (NAT) → hold → graceful
/// stop. The owner exits 0 only if every cycle passed.
final class HeadlessRunner: @unchecked Sendable {
  let bundle: VMBundle
  let log: EventLog
  let runDir: String?
  let stopFile: String?
  let hold: Double  // seconds after the guest is reachable; < 0 means until the stop file appears
  let cycles: Int
  let cpus: Int
  let memoryGiB: UInt64
  let queue = DispatchQueue(label: "dev.iso.vzprobe.vm")
  let boot: BootIdentity

  private let lock = NSLock()
  private var host: VMHost?
  private var cycle = 0
  private var guestIPValue: String?
  private var terminating = false

  init(bundle: VMBundle, log: EventLog, args: Arguments) {
    self.bundle = bundle
    self.log = log
    runDir = args.value("--run-dir")
    stopFile = args.value("--stop-file")
    hold = args.double("--hold", 0)
    cycles = max(1, args.int("--cycles", 1))
    cpus = args.int("--cpus", 4)
    memoryGiB = UInt64(args.int("--memory-gib", 8))
    boot = BootIdentity(log: log, key: bundle.helperKey)
  }

  var state: String { lock.withLock { host }?.state ?? "none" }

  // MARK: status file (read by the driver; works across users)

  func startStatusWriter() {
    guard let runDir else { return }
    let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.iso.vzprobe.status"))
    t.schedule(deadline: .now(), repeating: 1.0)
    t.setEventHandler { [self] in
      let (c, ip) = lock.withLock { (cycle, guestIPValue) }
      writeJSON(
        [
          "pid": Int(getpid()), "cycle": c, "vm_state": state, "guest_ip": ip ?? NSNull(),
          "t": Date().timeIntervalSince1970, "boot_id": boot.bootID ?? NSNull(),
          "helper_generation": boot.generation,
        ], to: runDir + "/status.json")
    }
    t.resume()
    statusTimer = t
  }
  private var statusTimer: DispatchSourceTimer?

  // MARK: run

  func run() async -> Bool {
    var allPass = true
    for i in 1...cycles {
      lock.withLock { cycle = i }
      let r = await runCycle(i)
      log.emit("cycle_result", r)
      if r["pass"] as? Bool != true { allPass = false }
      if lock.withLock({ terminating }) { break }
    }
    return allPass
  }

  func terminate(signal: Int32) {
    let host = lock.withLock { () -> VMHost? in
      terminating = true
      return self.host
    }
    log.emit("owner_signal", ["signal": Int(signal)])
    Task {
      if let host {
        let r = await host.forceStop()
        log.emit("vm_force_stop_on_signal", r)
      }
      exit(3)
    }
  }

  func runCycle(_ n: Int) async -> [String: Any] {
    var r: [String: Any] = ["cycle": n, "pass": false]
    lock.withLock { guestIPValue = nil }
    boot.reset()

    let config: VZVirtualMachineConfiguration
    do {
      config = try makeConfiguration(bundle, cpus: cpus, memoryGiB: memoryGiB)
      try config.validate()
      r["validation"] = "pass"
      log.emit("vm_validation", ["result": "pass"])
    } catch {
      r["validation"] = "fail"
      r["validation_error"] = errorInfo(error)
      log.emit("vm_validation", ["result": "fail", "error": errorInfo(error)])
      return r
    }

    let host = VMHost(configuration: config, queue: queue, log: log, boot: boot)
    lock.withLock { self.host = host }
    defer {
      host.teardown()
      lock.withLock { self.host = nil }
    }
    let t0 = Date()
    let started = await host.start()
    r["start"] = started["result"]
    r["vm_instance"] = host.instance
    if let e = started["error"] { r["start_error"] = e }
    guard started["result"] as? String == "pass" else { return r }
    let running = started["running"] as? Bool == true
    r["running"] = running

    // Guest independently reachable, checked concurrently: vsock hello from
    // the guest helper, and the NAT lease + SSH banner.
    var banner: String?
    let mac = bundle.macAddress
    var nextBannerProbe = Date()
    _ = await waitUntil(600, interval: 0.5) {
      if host.state != "running" { return true }
      if banner == nil, let mac, Date() >= nextBannerProbe {
        nextBannerProbe = Date().addingTimeInterval(2)
        if let ip = guestIP(mac: mac) {
          lock.withLock { guestIPValue = ip }
          banner = sshBanner(ip: ip)
          if let banner {
            log.emit(
              "guest_ssh_banner",
              [
                "banner": banner, "ip": ip, "seconds": Date().timeIntervalSince(t0),
                "method": "/usr/bin/nc", "direct_connect_errno": directConnectErrno(ip: ip),
              ])
          }
        }
      }
      return boot.hello != nil && banner != nil
    }
    r["guest_hello"] = boot.hello != nil
    if let h = boot.hello {
      r["guest_boot_id"] = h["boot"]
      r["guest_build"] = h["build"]
      r["guest_product_version"] = h["product_version"]
    }
    r["guest_ip"] = lock.withLock { guestIPValue } ?? NSNull()
    r["guest_ssh_banner"] = banner ?? NSNull()
    r["guest_reachable_seconds"] = Date().timeIntervalSince(t0)

    // Hold: the driver SSHes in and reads guest state while we wait.
    if hold != 0 {
      _ = await waitUntil(hold < 0 ? 86400 : hold, interval: 0.5) {
        stopFile.map { FileManager.default.fileExists(atPath: $0) } == true
          || host.state != "running"
      }
    }
    if let stopFile { try? FileManager.default.removeItem(atPath: stopFile) }

    let stop = await host.stop()
    r.merge(stop) { $1 }
    r["pass"] =
      r["validation"] as? String == "pass" && r["start"] as? String == "pass" && running
      && r["guest_hello"] as? Bool == true && banner != nil
      // A stop we asked for, while running, that ended without a forced stop.
      && stop["graceful_stop"] as? Bool == true
    return r
  }
}

func runHeadless(_ args: Arguments) -> Never {
  guard let path = args.positional.first else { die("usage: vm-run <bundle> [--run-dir D] ...") }
  let runDir = args.value("--run-dir")
  if let runDir {
    try? FileManager.default.createDirectory(atPath: runDir, withIntermediateDirectories: true)
  }
  let runID = args.value("--run-id") ?? UUID().uuidString
  let log = EventLog(
    path: runDir.map { $0 + "/vm-events.jsonl" }, runID: runID,
    context: args.value("--context") ?? "unknown")
  let ctx = hostContext(windowServer: false)
  if let runDir { writeJSON(ctx, to: runDir + "/context.json") }
  log.emit("owner_start", ["mode": "vm-run", "argv": args.all, "host_context": ctx])

  let runner = HeadlessRunner(
    bundle: VMBundle(root: URL(fileURLWithPath: path)), log: log, args: args)
  runner.startStatusWriter()
  for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    src.setEventHandler { runner.terminate(signal: sig) }
    src.resume()
    signalSources.append(src)
  }
  Task {
    let pass = await runner.run()
    log.emit("owner_exit", ["status": pass ? 0 : 1])
    exit(pass ? 0 : 1)
  }
  dispatchMain()
}

nonisolated(unsafe) var signalSources: [any DispatchSourceSignal] = []
