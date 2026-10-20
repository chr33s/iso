import ArgumentParser
import Foundation
import IsoCICore

/// Registers the controller services on a runtime. Both `serve` and the
/// in-process dispatcher use this, so every command sees the same services.
enum Services {
  static func install(_ runtime: Runtime) throws(CIError) {
    let path = runtime.root.configuration
    let load: @Sendable () -> Result<CIConfiguration, CIError> = {
      do throws(CIError) { return .success(try CIConfiguration.load(path: path)) } catch {
        return .failure(error)
      }
    }
    runtime.controller.add(
      ConnectedPoolService(
        store: runtime.store, provider: runtime.driver, loadConfiguration: load,
        clients: ConnectedPoolService.installationClients(
          store: runtime.store, credentials: KeychainCredentialStore())))
    runtime.controller.add(
      PreflightService(
        root: runtime.root, store: runtime.store, objects: runtime.objects,
        provider: runtime.driver,
        executable: runtime.executable, loadConfiguration: load))
  }
}
