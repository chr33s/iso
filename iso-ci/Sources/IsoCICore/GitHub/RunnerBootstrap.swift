import Foundation

/// Guest commands that start and observe the official runner. JIT material
/// reaches the guest only on stdin: it never appears in host argv, in these
/// templates, or in recorded output.
package enum RunnerBootstrap {
  /// The guest state directory (relative to the guest user's home).
  package static let stateDirectory = ".iso-ci"

  /// How the runner reaches the network.
  package enum LaunchMode: Sendable, Equatable {
    /// GitHub-connected: the runner and its containers use the egress
    /// companion; with Docker, through the bridge base iso configures on
    /// Docker's gateway (a container's loopback is not the guest's).
    case connected(docker: Bool)
    /// Local preflight: the runner talks only to its endpoint on
    /// `guestPort`, so it and its containers get no proxy (Docker's daemon
    /// keeps its own for pulls); with Docker the endpoint is also served on
    /// the gateway through a guest-internal bridge.
    case preflight(docker: Bool, guestPort: UInt16)
  }

  /// Why the start command failed, by its exit status.
  package enum StartFailure: Int32, Sendable, CaseIterable {
    case alreadyStarted = 3
    case emptyJIT = 4
    case noDocker = 5
    case endpointUnreachable = 6
    case noEgressBridge = 7

    package var message: String {
      switch self {
      case .alreadyStarted: "the runner was already started in this VM"
      case .emptyJIT: "the JIT configuration was empty"
      case .noDocker: "the approved image declares docker but has none"
      case .endpointUnreachable:
        "the preflight endpoint is not reachable on Docker's gateway in the guest"
      case .noEgressBridge: "the guest has no egress bridge for containers"
      }
    }

    package static func describe(_ status: Int32) -> String {
      Self(rawValue: status)?.message ?? "the runner did not start (exit \(status))"
    }
  }

  /// Reads the JIT configuration from stdin into a private file, prepares
  /// the runner's network for `mode`, then starts `run.sh --jitconfig`
  /// detached; the file is removed once read, and the runner's exit status
  /// is written to `runner.exit` when it ends.
  package static func start(runnerDirectory: String, jit: RedactedSecret, mode: LaunchMode)
    -> GuestCommand
  {
    let gateway = GuestEndpointHost.dockerGateway.rawValue
    let docker: Bool
    let egress: String
    switch mode {
    case .connected(let withDocker):
      docker = withDocker
      // Base iso writes the bridge URL into the guest user's Docker config
      // on every filtered boot; without Docker the session proxy is used.
      egress = """
        if [ -r /etc/environment ]; then set -a; . /etc/environment; set +a; fi
        proxy="${HTTPS_PROXY:-${https_proxy:-}}"
        if [ -n "$proxy" ] && [ "$docker" = docker ]; then
          proxy=$(jq -r '.proxies.default.httpsProxy // empty' "$HOME/.docker/config.json" 2>/dev/null || true)
          [ -n "$proxy" ] || { echo "no egress bridge for containers" >&2; exit 7; }
        fi
        noproxy="${NO_PROXY:-${no_proxy:-localhost,127.0.0.1}}"
        if [ -n "$proxy" ]; then
          printf 'https_proxy=%s\\nHTTPS_PROXY=%s\\nhttp_proxy=%s\\nHTTP_PROXY=%s\\nno_proxy=%s\\nNO_PROXY=%s\\n' \\
            "$proxy" "$proxy" "$proxy" "$proxy" "$noproxy" "$noproxy" > "$dir/.env"
        fi
        """
    case .preflight(let withDocker, let port):
      docker = withDocker
      let pattern = gateway.replacingOccurrences(of: ".", with: "\\.")
      egress = """
        unset HTTP_PROXY http_proxy HTTPS_PROXY https_proxy
        if [ "$docker" = docker ]; then
          cfg="$HOME/.docker/config.json"
          if [ -s "$cfg" ]; then jq 'del(.proxies)' "$cfg" > "$cfg.iso" && mv "$cfg.iso" "$cfg"; fi
          printf '%s\\n' '[Unit]' 'Description=iso-ci preflight endpoint for containers' \\
            '[Socket]' 'ListenStream=\(gateway):\(port)' 'FreeBind=yes' \\
            | sudo tee /etc/systemd/system/iso-ci-endpoint.socket >/dev/null
          printf '%s\\n' '[Unit]' 'Requires=iso-ci-endpoint.socket' '[Service]' \\
            'ExecStart=/usr/lib/systemd/systemd-socket-proxyd 127.0.0.1:\(port)' \\
            | sudo tee /etc/systemd/system/iso-ci-endpoint.service >/dev/null
          sudo systemctl daemon-reload
          sudo systemctl restart iso-ci-endpoint.socket
          for _ in $(seq 1 30); do
            ip -4 addr show docker0 2>/dev/null | grep -q 'inet \(pattern)/' && break
            sleep 1
          done
          reached=
          for _ in $(seq 1 30); do
            if (exec 3<>/dev/tcp/\(gateway)/\(port)) 2>/dev/null; then reached=1; break; fi
            sleep 1
          done
          [ -n "$reached" ] || { echo "endpoint unreachable on \(gateway)" >&2; exit 6; }
        fi
        """
    }
    let script = """
      set -eu
      umask 077
      dir="$1"
      docker="$2"
      state="$HOME/\(stateDirectory)"
      mkdir -p "$state"
      if [ -e "$state/runner.pid" ]; then echo "runner already started" >&2; exit 3; fi
      cat > "$state/jit"
      [ -s "$state/jit" ] || { echo "empty JIT configuration" >&2; exit 4; }
      if [ "$docker" = docker ]; then
        command -v docker >/dev/null 2>&1 || { echo "the approved image has no docker" >&2; exit 5; }
      fi
      \(egress.replacingOccurrences(of: "\n", with: "\n  "))
      cd "$dir"
      # The usual umask: containers may run as another user.
      nohup setsid sh -c 'cfg=$(cat "$1"); rm -f "$1"; umask 022; ./run.sh --jitconfig "$cfg"; echo $? > "$2"' \\
        sh "$state/jit" "$state/runner.exit" > "$state/runner.log" 2>&1 < /dev/null &
      echo $! > "$state/runner.pid"
      """
    return GuestCommand(
      [
        "/bin/bash", "-c", script, "iso-ci-bootstrap", runnerDirectory,
        docker ? "docker" : "nodocker",
      ],
      stdin: jit.bytes, timeoutSeconds: 180, outputLimit: 16 << 10, recordOutput: false)
  }

  /// The version file the approved image writes next to the runner.
  package static let versionFile = ".iso-ci-runner-version"

  /// Reads the installed official runner version (before any JIT material
  /// is released to the guest).
  package static func version(runnerDirectory: String) -> GuestCommand {
    GuestCommand(
      ["/bin/sh", "-c", "head -c 64 \"$1/\(versionFile)\"", "iso-ci-version", runnerDirectory],
      timeoutSeconds: 30, outputLimit: 256)
  }

  /// `2.338.0`-style versions only (a leading `v` is accepted).
  package static func parseVersion(_ result: GuestCommandResult) -> String? {
    guard result.succeeded else { return nil }
    var text = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("v") { text.removeFirst() }
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
      return nil
    }
    return text
  }

  /// Prints `running`, `exited <status>` or `absent`.
  package static func status() -> GuestCommand {
    let script = """
      state="$HOME/\(stateDirectory)"
      if [ -s "$state/runner.exit" ]; then printf 'exited %s\\n' "$(head -c 16 "$state/runner.exit")"
      elif [ -s "$state/runner.pid" ] && kill -0 "$(cat "$state/runner.pid")" 2>/dev/null; then echo running
      elif [ -s "$state/runner.pid" ]; then echo vanished
      else echo absent; fi
      """
    return GuestCommand(["/bin/sh", "-c", script], timeoutSeconds: 30, outputLimit: 256)
  }

  package enum ProcessState: Sendable, Equatable {
    case running
    case exited(Int32)
    /// Started, but gone without recording a status.
    case vanished
    case absent
  }

  package static func parseStatus(_ result: GuestCommandResult) -> ProcessState? {
    guard result.succeeded else { return nil }
    let text = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    switch text {
    case "running": return .running
    case "absent": return .absent
    case "vanished": return .vanished
    default:
      guard text.hasPrefix("exited "), let status = Int32(text.dropFirst(7)) else { return nil }
      return .exited(status)
    }
  }

}
