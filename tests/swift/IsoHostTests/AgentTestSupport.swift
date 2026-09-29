import Foundation
import IsoConfiguration
import IsoCore
import Synchronization

@testable import IsoHost

/// A scratch directory under `/tmp` (short enough for control sockets).
func scratchDirectory(_ label: String) throws -> String {
  var template = Array("/tmp/iso-\(label)-XXXXXX".utf8CString)
  guard let path = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else {
    throw HostError("mkdtemp failed")
  }
  return BinaryResolver.canonicalPath(String(cString: path))
}

func writeFile(_ path: String, _ text: String, mode: mode_t = 0o644) throws {
  try FileManager.default.createDirectory(
    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try Data(text.utf8).write(to: URL(fileURLWithPath: path))
  chmod(path, mode)
}

func readFile(_ path: String) -> String? {
  FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
}

func testConfig(_ body: String = "", home: String? = nil, variables: [String: String] = [:])
  throws -> IsoConfig
{
  try ConfigLoader.decode(
    ConfigLoader.parse(Array("{\(body)}".utf8), format: .jsonc, path: "c", limits: .configuration),
    path: "c", environment: ConfigEnvironment(home: home, variables: variables))
}

func testInstance(_ directory: String, index: UInt16 = 0, image: ImageName = .default) throws
  -> Instance
{
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  return Instance(
    name: try InstanceName("dev"), index: InstanceIndex(index)!, directory: directory, image: image)
}

/// Captures diagnostics lines.
final class LogSink: Sendable {
  let lines = Mutex<[String]>([])
  var diagnostics: Diagnostics {
    Diagnostics(verbosity: 2) { [self] line in self.lines.withLock { $0.append(line) } }
  }
  var text: String { lines.withLock { $0.joined(separator: "\n") } }
}

/// A fake guest reached through stub `ssh`/`scp`: remote commands run
/// locally under `/bin/sh` with `HOME` set to a scratch guest home, the
/// agent binaries are logging fakes, and tunnel masters and `-O forward`
/// requests are simulated. Nothing reaches a network.
struct FakeGuest {
  let root: String
  let environment: [String: String]
  let sink = LogSink()

  var home: String { root + "/home" }
  var client: SSHClient { SSHClient(environment: environment) }
  var target: SSHTarget {
    SSHTarget(
      host: "10.231.1.2", port: 22, user: .default, keyPath: root + "/key",
      knownHosts: root + "/known_hosts", alias: "coop-test.coop")
  }

  init() throws {
    root = try scratchDirectory("guest")
    environment = [
      "PATH": root + "/bin:/usr/bin:/bin", "STUB": root, "HOME": root + "/hosthome",
      "TMPDIR": NSTemporaryDirectory(),
    ]
    try FileManager.default.createDirectory(
      atPath: root + "/home", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      atPath: root + "/hosthome", withIntermediateDirectories: true)
    try writeFile(
      root + "/bin/ssh",
      #"""
      #!/bin/sh
      # ssh sees only the guest transport environment: find the stub root
      # from this script's own path.
      S="$(cd "$(dirname "$0")/.." && pwd)"
      last=""
      for a in "$@"; do last="$a"; done
      case " $* " in
        *" -N "*)
          prev=""; for a in "$@"; do [ "$prev" = "-S" ] && sock="$a"; prev="$a"; done
          printf 'master %s\n' "$*" >> "$S/tunnels.log"
          [ -f "$S/flags/master-exits" ] && exit 255
          : > "$sock"
          exec "$S/tunnel/ssh" 60 ;;
        *" -O "*)
          printf 'forward %s\n' "$*" >> "$S/tunnels.log"
          [ -f "$S/flags/forward-fails" ] && exit 1
          exit 0 ;;
      esac
      printf '%s\n' "$last" >> "$S/commands.log"
      printf 'ARGV %s\n' "$*" >> "$S/argv.log"
      for v in ANTHROPIC_API_KEY OPENAI_API_KEY ISO_LOCAL_API_KEY GITHUB_TOKEN CLAUDE_CODE_OAUTH_TOKEN GUEST_VAR; do
        eval "isset=\${$v+x}"
        if [ -n "$isset" ]; then eval "printf '%s=%s\n' $v \"\$$v\"" >> "$S/env.log"; fi
      done
      case "$last" in
        "test -x "*) [ -f "$S/flags/test-x-fails" ] && exit 1; exit 0 ;;
      esac
      cmd=$(printf '%s' "$last" | sed -e "s#/home/ubuntu/.local/bin/claude#$S/guestbin/claude#g" -e "s#/usr/local/bin/codex#$S/guestbin/codex#g")
      HOME="$S/home" PATH="$S/guestbin:/usr/bin:/bin" exec /bin/sh -c "$cmd"
      """#, mode: 0o755)
    // Tunnel masters must show up in `ps` as `ssh`.
    try FileManager.default.createDirectory(
      atPath: root + "/tunnel", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: root + "/tunnel/ssh", withDestinationPath: "/bin/sleep")
    try writeFile(
      root + "/bin/scp",
      #"""
      #!/bin/sh
      # ssh sees only the guest transport environment: find the stub root
      # from this script's own path.
      S="$(cd "$(dirname "$0")/.." && pwd)"
      n=$#
      eval "src=\${$((n-1))}"
      eval "remote=\${$n}"
      dest="${remote#*:}"
      case "$dest" in
        "~/"*) dest="$S/home/${dest#\~/}" ;;
        "./"*) dest="$S/home/${dest#./}" ;;
        *) dest="$S/home/$dest" ;;
      esac
      printf 'scp %s -> %s\n' "$src" "$remote" >> "$S/scp.log"
      mkdir -p "$(dirname "$dest")"
      if [ -d "$dest" ]; then cp -R "$src" "$dest/"; else cp -R "$src" "$dest"; fi
      """#, mode: 0o755)
    try writeFile(
      root + "/guestbin/claude",
      #"""
      #!/bin/sh
      STUB="$(cd "$(dirname "$0")/.." && pwd)"
      printf 'claude %s\n' "$*" >> "$STUB/guest-calls.log"
      case "$1" in
        --version) echo "2.1.0 (Claude Code)" ;;
        -p) printf '{"theme":"dark"}' > "$HOME/.claude.json" ;;
      esac
      """#, mode: 0o755)
    try writeFile(
      root + "/guestbin/codex",
      #"""
      #!/bin/sh
      STUB="$(cd "$(dirname "$0")/.." && pwd)"
      printf 'codex %s\n' "$*" >> "$STUB/guest-calls.log"
      case "$1" in --version) echo "codex-cli 0.50.0" ;; esac
      """#, mode: 0o755)
    try writeFile(
      root + "/guestbin/timeout", "#!/bin/sh\nshift\nexec \"$@\"\n", mode: 0o755)
    try writeFile(
      root + "/guestbin/sudo",
      "#!/bin/sh\nSTUB=\"$(cd \"$(dirname \"$0\")/..\" && pwd)\"\nprintf 'sudo %s\\n' \"$*\" >> \"$STUB/guest-calls.log\"\ncat > \"$STUB/sudo-stdin\"\n",
      mode: 0o755)
    try writeFile(
      root + "/guestbin/gh",
      "#!/bin/sh\nSTUB=\"$(cd \"$(dirname \"$0\")/..\" && pwd)\"\nprintf 'gh %s\\n' \"$*\" >> \"$STUB/guest-calls.log\"\n",
      mode: 0o755)
  }

  func flag(_ name: String) throws { try writeFile(root + "/flags/" + name, "") }

  func log(_ name: String) -> [String] { readFile(root + "/" + name).map(rustLines) ?? [] }

  func guestFile(_ path: String) -> String? { readFile(home + "/" + path) }

  func proxies(_ resolver: CredentialResolver? = nil, iso: String? = nil) -> ProxyLauncher {
    ProxyLauncher(
      environment: environment, resolver: resolver ?? CredentialResolver(environment: environment),
      diagnostics: sink.diagnostics, isoExecutable: iso, sandboxExec: root + "/bin/sandbox-exec",
      controlRoot: root)
  }

  func bootstrap(
    _ config: IsoConfig, github: any GitHubTokenSource = NoGitHub(), iso: String? = nil
  ) -> AgentBootstrap {
    let resolver = CredentialResolver(environment: environment)
    return AgentBootstrap(
      config: config, client: client, environment: environment, home: root + "/hosthome",
      resolver: resolver, proxies: proxies(resolver, iso: iso), github: github,
      diagnostics: sink.diagnostics)
  }

  /// `iso-proxy` stand-in: saves its stdin, then answers HTTP 401 on the
  /// listen address. `sandbox-exec` stand-in: logs its argv and execs the
  /// last argument (the proxy).
  func installProxyStubs(behavior: String = "serve") throws -> String {
    try writeFile(
      root + "/bin/sandbox-exec",
      "#!/bin/sh\nenv > \"\(root)/sandbox-env\"\nprintf '%s\\n' \"$@\" > \"\(root)/sandbox-argv\"\nfor a in \"$@\"; do last=\"$a\"; done\nexec \"$last\"\n",
      mode: 0o755)
    try writeFile(
      root + "/app/iso-proxy",
      """
      #!/usr/bin/python3
      import json, os, socket, sys
      data = sys.stdin.read()
      open("\(root)/proxy-stdin", "w").write(data)
      open("\(root)/proxy-env", "w").write(json.dumps(dict(os.environ)))
      if "\(behavior)" == "exit":
          sys.stderr.write("boom: jail could not be established\\n")
          sys.exit(7)
      host, port = json.loads(data)["listen"].rsplit(":", 1)
      s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
      s.bind((host, int(port))); s.listen(8)
      while True:
          c, _ = s.accept()
          try:
              c.recv(4096); c.sendall(b"HTTP/1.1 401 Unauthorized\\r\\nContent-Length: 0\\r\\n\\r\\n")
          finally:
              c.close()
      """, mode: 0o755)
    try writeFile(root + "/app/iso", "", mode: 0o755)
    return root + "/app/iso"
  }

  func remove() {
    // Stop anything a test left running (tunnel masters, proxies).
    for name in (try? FileManager.default.subpathsOfDirectory(atPath: root)) ?? []
    where name.hasSuffix(".pid") {
      if let text = readFile(root + "/" + name), let pid = Int32(text.trimmingUnicodeWhitespace()),
        pid > 0
      {
        kill(pid, SIGKILL)
      }
    }
    try? FileManager.default.removeItem(atPath: root)
  }
}

/// `github = off`: nothing forwarded.
struct NoGitHub: GitHubTokenSource {
  func instanceRepo(_ instance: Instance) -> RepoSlug? { nil }
  func activeAssignment(_ instance: Instance) throws -> RepoSlug? { nil }
  func token(repo: RepoSlug?) throws -> Secret<String>? { nil }
  func resolvePAT(_ repo: RepoSlug) throws -> Secret<String> { throw HostError("no PAT") }
  func configureGuest(_ client: SSHClient, _ session: SSHSession) throws {}
}
