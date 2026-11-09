import ArgumentParser
import Foundation
import IsoCICore

/// Registers the controller services on a runtime. Both `serve` and the
/// in-process dispatcher use this, so every command sees the same services.
/// Only a serving controller starts scale-set listeners and allocation
/// supervisors: an in-process command exits when it is done.
enum Services {
  static func install(_ runtime: Runtime, serving: Bool = false, trace: ProtocolTrace? = nil)
    throws(CIError)
  {
    let path = runtime.root.configuration
    let load: @Sendable () -> Result<CIConfiguration, CIError> = {
      do throws(CIError) { return .success(try CIConfiguration.load(path: path)) } catch {
        return .failure(error)
      }
    }
    let clients = ConnectedPoolService.installationClients(
      store: runtime.store, credentials: KeychainCredentialStore())
    let board = SchedulerBoard()
    var feeds: ConnectedPoolService.ScaleSetFeedFactory?
    var supervision: ConnectedPoolService.AllocationSupervision?
    if serving {
      let store = runtime.store
      let owner = "iso-ci-\(try store.controllerID().short)-\(getpid())"
      feeds = { (name, pool, installation) throws(CIError) -> any ScaleSetFeed in
        let client = try clients(installation)
        let scaleSets = ScaleSetClient(http: URLSessionGitHubHTTP())
        let listener = try ScaleSetListener(
          pool: name, configuration: pool,
          authority: InstallationScaleSetAuthority(client: client, scaleSets: scaleSets),
          client: scaleSets, store: store, owner: owner, trace: trace)
        listener.start()
        return listener
      }
      supervision = .init(
        AllocationSupervisors.standard(root: runtime.root, executable: runtime.executable))
    }
    runtime.controller.add(
      ConnectedPoolService(
        store: runtime.store, provider: runtime.driver, loadConfiguration: load,
        clients: clients, board: board, external: LocalExternalUsageProbe(), feeds: feeds,
        supervision: supervision, trace: trace))
    runtime.controller.add(
      PreflightService(
        root: runtime.root, store: runtime.store, objects: runtime.objects,
        provider: runtime.driver,
        executable: runtime.executable, loadConfiguration: load, board: board))
    runtime.controller.add(SchedulerStatusService(board: board))
  }
}
