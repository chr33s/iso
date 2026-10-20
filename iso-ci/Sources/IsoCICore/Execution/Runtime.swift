import Foundation

/// Builds the controller's parts for one data root. `serve` runs the loop;
/// other commands either talk to a running controller over the control
/// channel or, when none runs, take the ownership lock and dispatch the
/// same request in process — the same records and authorization either way.
package struct Runtime: Sendable {
  package let root: DataRoot
  package let store: ControllerStore
  package let objects: ObjectStore
  package let hosts: HostDirectory
  package let driver: AllocationDriver
  package let controller: Controller
  package let iso: String
  package let executable: String

  package static func open(
    root: DataRoot, iso explicitISO: String?, isoConfig explicitISOConfig: String? = nil,
    environment: [String: String],
    clock: any CIClock = SystemClock()
  ) throws(CIError) -> Runtime {
    try root.prepare()
    let database = try Database(path: root.database)
    let store = try ControllerStore(database: database, clock: clock)
    let objects = try ObjectStore(root: root, database: database, clock: clock)
    let iso = try resolveISO(explicitISO, store: store, environment: environment)
    let isoConfig = try resolveISOConfig(explicitISOConfig, store: store)
    let executable = try currentExecutable()
    let hosts = HostDirectory(store: store, iso: iso, isoConfig: isoConfig)
    let driver = AllocationDriver(
      store: store, hosts: hosts, root: root, iso: iso, isoConfig: isoConfig,
      relayExecutable: executable, objects: objects)
    var configuration: CIConfiguration?
    var configurationError: String?
    do { configuration = try CIConfiguration.load(path: root.configuration) } catch {
      configurationError = error.message
    }
    let controller = Controller(
      root: root, store: store, driver: driver, hosts: hosts, configuration: configuration,
      configurationError: configurationError)
    return Runtime(
      root: root, store: store, objects: objects, hosts: hosts, driver: driver,
      controller: controller,
      iso: iso, executable: executable)
  }

  /// The explicitly installed `iso` the operator chose (recorded once), or
  /// the first absolute candidate on a fixed list. Never a project path.
  /// An operator-chosen iso configuration file (`iso --config`), recorded
  /// once; nil means iso's default `~/.iso/config.jsonc`.
  package static func resolveISOConfig(_ explicit: String?, store: ControllerStore) throws(CIError)
    -> String?
  {
    if let explicit {
      guard explicit.hasPrefix("/"), access(explicit, R_OK) == 0 else {
        throw CIError.config("--iso-config must be an absolute path to a readable iso config")
      }
      try store.setMeta("iso_config", explicit)
      return explicit
    }
    return try store.meta("iso_config")
  }

  package static func resolveISO(
    _ explicit: String?, store: ControllerStore, environment: [String: String]
  )
    throws(CIError) -> String
  {
    if let explicit {
      guard explicit.hasPrefix("/"), access(explicit, X_OK) == 0 else {
        throw CIError.config("--iso must be an absolute path to an executable iso")
      }
      try requireRouteSafe(explicit)
      try store.setMeta("iso_executable", explicit)
      return explicit
    }
    if let recorded = try store.meta("iso_executable"), access(recorded, X_OK) == 0 {
      return recorded
    }
    let home = environment["HOME"] ?? NSHomeDirectory()
    for candidate in ["/usr/local/bin/iso", "/opt/homebrew/bin/iso", home + "/.local/bin/iso"]
    where access(candidate, X_OK) == 0 {
      try requireRouteSafe(candidate)
      return candidate
    }
    throw CIError(.unsupported, "iso is not installed; pass --iso /path/to/iso")
  }

  package static func currentExecutable() throws(CIError) -> String {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size) + 1)
    guard _NSGetExecutablePath(&buffer, &size) == 0 else {
      throw CIError(.internalError, "cannot resolve the iso-ci executable path")
    }
    let path = String(
      decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let resolved = (path as NSString).resolvingSymlinksInPath
    return (resolved as NSString).standardizingPath
  }
}

/// Talks to the running controller, or runs the request in process when no
/// controller holds the data root.
package struct ControlDispatcher: Sendable {
  package let root: DataRoot
  package let makeRuntime: @Sendable () throws(CIError) -> Runtime

  package init(root: DataRoot, makeRuntime: @escaping @Sendable () throws(CIError) -> Runtime) {
    self.root = root
    self.makeRuntime = makeRuntime
  }

  package func call(
    _ method: String, _ params: JSONValue = [:],
    inProcess configure: ((Runtime) throws(CIError) -> Void)? = nil
  )
    throws(CIError) -> JSONValue
  {
    let client = ControlClient(path: root.controlSocket)
    do {
      return try client.call(method, params)
    } catch {
      guard error.code == .controllerUnavailable else { throw error }
    }
    try root.prepare()
    guard let lock = try OwnershipLock.attempt(path: root.lock) else {
      throw CIError(
        .controllerBusy, "the controller owns the data root but is not answering; retry shortly")
    }
    defer { lock.release() }
    let runtime = try makeRuntime()
    try configure?(runtime)
    return try runtime.controller.handle(ControlRequest(method: method, params: params)).get()
  }
}
