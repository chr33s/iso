import ArgumentParser
import Foundation
import IsoCICore

/// `iso-ci setup`: an idempotent frontend to the same controller records as
/// every other command (spec section 8). Each step reports done, skipped or
/// what the operator must do; nothing is committed, pushed or installed
/// without an explicit flag.
struct Setup: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract:
      "Idempotent onboarding: hosts, configuration, approvals, GitHub App, service, smoke test",
    discussion: """
      Steps run in order and each is safe to repeat:
        --host ALIAS            enable an iso host (local or an `iso host add` enrollment) and pin it
        --write-config          write a starting config.yaml for review (never overwrites)
        --approve               approve the configuration's descriptor digests (shows them first)
        --create-app            create a GitHub App from a manifest in your browser
        --app-id/--private-key  or connect an operator-owned App instead
        --installation-id       verify the installation you completed on GitHub
        --find-installation     or find it on the configured repository, then verify it
        --service install       install the per-user controller service (explicit)
        --smoke-workflow PATH   write the smoke workflow for review (never committed)
      """)

  @OptionGroup var global: GlobalOptions
  @Option(name: .customLong("host"), help: "iso host alias to enable for CI (repeatable)")
  var hosts: [String] = []
  @Flag(help: "Write a starting config.yaml if none exists") var writeConfig = false
  @Option(help: "Repository for the starting configuration and smoke test (OWNER/REPOSITORY)")
  var repository: String?
  @Flag(help: "Approve the descriptor digests the configuration uses") var approve = false
  @Flag(help: "Create a GitHub App through the manifest flow (opens your browser)") var createApp =
    false
  @Option(help: "Create the App under this organization instead of your account")
  var appOrganization: String?
  @Option(help: "Connect an existing operator-owned App by id") var appID: Int64?
  @Option(help: "PEM private key file for --app-id (read once, stored in the login keychain)")
  var privateKey: String?
  @Option(help: "Installation id to verify after installing the App") var installationID: Int64?
  @Flag(
    help: "Find the App's installation on --repository (or the pools' repository) and verify it")
  var findInstallation = false
  @Option(help: "Configuration name for the installation") var installationName: String =
    "selected-installation"
  @Option(help: "Expected installation account (user or organization)") var account: String?
  @Option(help: "Service choice: install (launchd user service) or foreground") var service: String?
  @Option(help: "Write the smoke workflow to this path for review") var smokeWorkflow: String?
  @Option(help: "Pool whose labels the smoke workflow uses") var pool: String = "validation"

  func validate() throws {
    if createApp && privateKey != nil {
      throw ValidationError("use --create-app or --app-id/--private-key, not both")
    }
    if privateKey != nil && appID == nil { throw ValidationError("--private-key needs --app-id") }
    if findInstallation && installationID != nil {
      throw ValidationError("use --installation-id or --find-installation, not both")
    }
    if let service, !["install", "foreground"].contains(service) {
      throw ValidationError("--service must be install or foreground")
    }
  }

  func run() throws {
    try global.run { () throws(CIError) in
      var report: [String: JSONValue] = [:]
      let root = global.dataRoot
      try root.prepare()

      // Hosts: existing local or enrolled iso hosts only.
      var enabled: [JSONValue] = []
      for alias in hosts {
        let value = try global.call("host.enable", ["host": .string(alias)])
        enabled.append(value)
        step("host \(alias): enabled (host id \(string(value["hostID"])))")
      }
      report["hosts"] = .array(enabled)

      if writeConfig {
        if access(root.configuration, F_OK) == 0 {
          step("config: \(root.configuration) exists; left unchanged")
        } else {
          guard let repository else {
            throw CIError.invalid("--write-config needs --repository OWNER/REPOSITORY")
          }
          _ = try RepositoryName(repository)
          let template = CIConfiguration.template(
            repository: repository, host: hosts.first ?? "local")
          _ = try CIConfiguration.parse(template)
          try PrivateFiles.write(Array(template.utf8), to: root.configuration)
          step("config: wrote \(root.configuration); review it, then run `iso-ci setup --approve`")
        }
      }

      // Approve descriptor digests (shown before recording).
      if approve {
        let preview = try global.call("approve", ["dry_run": true])
        for row in preview["descriptors"]?.arrayValue ?? [] {
          step(
            "approve \(string(row["kind"])) \(string(row["name"])) sha256:\(string(row["digest"]))\(row["changed"] == .bool(true) ? " (new)" : "")"
          )
        }
        report["approvals"] = try global.call("approve", ["dry_run": false])
      }

      // GitHub App: manifest flow or an operator-owned App.
      if createApp {
        let state = randomHex(bytes: 32)
        let server = try ManifestCallbackServer(state: state)
        let scopes: Set<ManifestFlow.ScopeKind> = [
          appOrganization == nil ? .repository : .organization
        ]
        let manifest = ManifestFlow.manifest(
          name: "iso-ci-\(randomHex(bytes: 3))", homepage: "https://github.com/chr33s/iso",
          redirectURL: server.callbackURL, scopes: scopes)
        let page = ManifestFlow.formPage(
          manifest: manifest,
          action: ManifestFlow.creationURL(organization: appOrganization, state: state))
        step("app: opening a local page that submits the App manifest to GitHub for your review")
        step(
          "app: requested permissions \(ManifestFlow.permissions(scopes).sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ", ")) (no Actions write)"
        )
        if let open = Subprocess.which("open") {
          _ = try? Subprocess.run(
            .init(executable: open, arguments: [server.formURL], timeout: .seconds(10)))
        }
        let code = try server.waitForCode(formPage: page, timeoutSeconds: 900)
        let app = try global.call("github.app.complete", ["code": .string(code)])
        report["app"] = app
        step(
          "app: created \(string(app["slug"])); install it on the repository or organization: \(string(app["install_url"]))"
        )
        step(
          "app: after installing, run `iso-ci setup --find-installation` to find and verify the installation"
        )
      } else if let appID, let privateKey {
        guard let bytes = try PrivateFiles.read(privateKey, limit: 16 << 10),
          let pem = String(validating: bytes, as: UTF8.self)
        else {
          throw CIError.invalid("cannot read \(privateKey) (a private regular file owned by you)")
        }
        let app = try global.call(
          "github.app.connect", ["app_id": .integer(appID), "private_key_pem": .string(pem)])
        report["app"] = app
        step(
          "app: connected \(string(app["slug"])); the key is in the login keychain (you may delete \(privateKey))"
        )
      }

      var installationID = self.installationID
      let config = try? CIConfiguration.load(path: root.configuration)
      if findInstallation {
        guard let app = appID ?? report["app"]?["app_id"]?.intValue ?? Self.singleAppID(global)
        else {
          throw CIError.invalid(
            "pass --app-id with --find-installation when more than one App is connected")
        }
        let configured = Set(
          (config?.pools.values ?? [:].values).compactMap { pool -> String? in
            if case .repository(let name) = pool.scope { return name.rawValue }
            return nil
          })
        guard let target = repository ?? (configured.count == 1 ? configured.first : nil) else {
          throw CIError.invalid("pass --repository OWNER/REPOSITORY with --find-installation")
        }
        let found = try global.call(
          "github.installation.find", ["app_id": .integer(app), "repository": .string(target)])
        installationID = found["installation_id"]?.intValue
        step("installation: found \(string(found["installation_id"])) on \(target)")
      }
      if let installationID {
        guard let app = appID ?? report["app"]?["app_id"]?.intValue ?? Self.singleAppID(global)
        else {
          throw CIError.invalid(
            "pass --app-id with --installation-id when more than one App is connected")
        }
        // Only the pools that use this installation decide what it must allow.
        var scopes: Set<String> = []
        for pool in config?.pools.values ?? [:].values
        where pool.installation.rawValue == installationName {
          switch pool.scope {
          case .repository: scopes.insert("repository")
          case .organization: scopes.insert("organization")
          }
        }
        if scopes.isEmpty { scopes = ["repository"] }
        var params: [String: JSONValue] = [
          "name": .string(installationName), "installation_id": .integer(installationID),
          "app_id": .integer(app), "scopes": .array(scopes.sorted().map { .string($0) }),
        ]
        if let account { params["account"] = .string(account) }
        report["installation"] = try global.call("github.installation.verify", .object(params))
        step("installation \(installationName): verified (\(installationID))")
        step(
          "authority: the controller evaluates each pool's GitHub-side guarantees; see `iso-ci status`"
        )
        step(
          "authority: a validation pool cannot withhold repository secrets or narrow GITHUB_TOKEN; restrict them on GitHub"
        )
      }

      if service == "install" {
        report["service"] = try UserService.apply(
          install: true, root: root, executable: try Runtime.currentExecutable(), iso: global.iso)
        step("service: installed and started")
      } else if service == "foreground" {
        step(
          "service: run `iso-ci serve` in a terminal; pools are inactive while it is not running")
      }

      if let smokeWorkflow {
        let config = try CIConfiguration.load(path: root.configuration)
        guard let poolConfig = config.pools[try Name(pool)] else {
          throw CIError.config("unknown pool \(pool)")
        }
        var group: String?
        if case .organization(_, let runnerGroup) = poolConfig.scope { group = runnerGroup }
        let text = SmokeWorkflow.generate(labels: poolConfig.labels, runnerGroup: group)
        guard access(smokeWorkflow, F_OK) != 0 else {
          throw CIError(.conflict, "\(smokeWorkflow) exists; choose another path")
        }
        do {
          // A fresh repository usually has no .github/workflows yet.
          let target = URL(fileURLWithPath: absolutePath(smokeWorkflow))
          try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
          try Data(text.utf8).write(to: target, options: .withoutOverwriting)
        } catch {
          throw CIError.storage("cannot write \(smokeWorkflow)")
        }
        step("smoke: wrote \(smokeWorkflow) for review; iso-ci never commits or pushes it")
        step(
          "smoke: dispatch it twice, then `iso-ci status` and `iso-ci inspect` both allocations; they must use different VMs and runners"
        )
      }

      for limitation in UserService.limitations { step("availability: \(limitation)") }
      report["limitations"] = .array(UserService.limitations.map { .string($0) })
      if global.json { Output.print(["ok": true, "result": .object(report)]) }
    }
  }

  private func step(_ text: String) {
    if !global.json { Output.line(text) }
  }

  private static func singleAppID(_ global: GlobalOptions) -> Int64? {
    let root = global.dataRoot
    guard let store = try? ControllerStore.open(root: root), let apps = try? store.apps(),
      apps.count == 1
    else { return nil }
    return apps[0].appID
  }
}
