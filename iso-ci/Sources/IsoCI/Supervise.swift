import ArgumentParser
import Foundation
import IsoCICore

/// `iso-ci internal-supervise`: one allocation's supervisor, started by the
/// serving controller in its own session with the allocation's lock on fd
/// 3. It outlives controller restarts; the kernel releases the lock when it
/// exits.
struct InternalSupervise: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "internal-supervise",
    abstract: "Supervise one allocation (the controller runs this).",
    shouldDisplay: false)

  @OptionGroup var global: GlobalOptions
  @Option(help: "The allocation to supervise") var allocation: String
  @Option(name: .customLong("lock-fd"), help: "The inherited, locked allocation lock")
  var lockFD: Int32

  func run() throws {
    try global.run { () throws(CIError) in
      let id = try AllocationID(allocation)
      let root = global.dataRoot
      let reporter = try SupervisorReporter(
        files: AllocationFiles(directory: root.allocations), allocation: id, lockFD: lockFD,
        clock: SystemClock())
      signal(SIGPIPE, SIG_IGN)
      signal(SIGHUP, SIG_IGN)
      let runtime = try Runtime.open(
        root: root, iso: global.iso, isoConfig: global.isoConfig,
        environment: ProcessInfo.processInfo.environment)
      let configuration: CIConfiguration
      do throws(CIError) {
        configuration = try CIConfiguration.load(path: root.configuration)
      } catch {
        reporter.report(.failed, detail: error.message)
        throw error
      }
      let launched = reporter.state
      guard let pool = configuration.pools[launched.pool],
        let installation = try runtime.store.installation(pool.installation)
      else {
        reporter.report(.failed, detail: "pool or installation is no longer configured")
        throw CIError(.notFound, "pool \(launched.pool) is not configured")
      }
      let client = try ConnectedPoolService.installationClients(
        store: runtime.store, credentials: KeychainCredentialStore())(installation)
      let base = InstallationRunnerService(client: client)
      var runners: any RunnerService = base
      if pool.scaleSet != nil {
        // Registration only: this listener never opens a message session.
        let scaleSets = ScaleSetClient(http: URLSessionGitHubHTTP())
        let feed = try ScaleSetListener(
          pool: launched.pool, configuration: pool,
          authority: InstallationScaleSetAuthority(client: client, scaleSets: scaleSets),
          client: scaleSets, store: runtime.store, owner: "iso-ci-supervisor-\(getpid())")
        runners = ScaleSetRunnerService(base: base, feed: feed)
      }
      let phase = SupervisorMain.run(
        allocation: id, reporter: reporter, store: runtime.store, provider: runtime.driver,
        configuration: configuration, runners: runners,
        controller: try runtime.store.controllerID())
      Output.note("supervisor for \(id) ended: \(phase.rawValue)")
    }
  }
}
