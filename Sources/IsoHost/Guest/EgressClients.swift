import Foundation
import IsoConfiguration
import IsoCore

/// Guest clients that never see an iso session's proxy variables, pointed at
/// this boot's filtered-egress companion: the Docker daemon (image pulls),
/// and containers and builds on Docker's default bridge (through a guest
/// bridge on its gateway, since a container's loopback is not the guest's).
/// git is set to send its proxy credentials up front. `/etc/environment`
/// (read by every PAM session, including non-interactive ssh commands)
/// carries the same proxy variables, so sessions opened through host
/// control — whose client cannot read the worker's capability — use it too.
/// Convenience only, as on every filtered guest: the companion enforces the
/// allowlist, and a guest that ignores or rewrites this gains nothing.
enum EgressClients {
  /// Docker's default bridge gateway, where containers reach the guest.
  static let dockerGateway = "172.17.0.1"

  /// Written by guest root. The proxy URL, which carries the per-boot
  /// capability, arrives on stdin and never on argv or in a log.
  static func script(port: UInt16, user: GuestUser) -> String {
    """
    set -eu
    umask 077
    IFS= read -r url
    bridge=$(printf '%s' "$url" | sed 's#@127\\.0\\.0\\.1:#@\(dockerGateway):#')
    d=/etc/systemd/system/docker.service.d
    mkdir -p "$d"
    conf=$(printf '[Service]\\nEnvironment="HTTPS_PROXY=%s" "HTTP_PROXY=%s" "NO_PROXY=localhost,127.0.0.1"\\n' "$url" "$url")
    changed=
    if [ "$(cat "$d/iso-egress-proxy.conf" 2>/dev/null || true)" != "$conf" ]; then
      printf '%s\\n' "$conf" > "$d/iso-egress-proxy.conf"
      changed=1
    fi
    printf '%s\\n' '[Unit]' 'Description=iso filtered egress for containers on the Docker bridge' \\
      '[Socket]' 'ListenStream=\(dockerGateway):\(port)' 'FreeBind=yes' \\
      > /etc/systemd/system/iso-egress-bridge.socket
    printf '%s\\n' '[Unit]' 'Requires=iso-egress-bridge.socket' '[Service]' \\
      'ExecStart=/usr/lib/systemd/systemd-socket-proxyd 127.0.0.1:\(port)' \\
      > /etc/systemd/system/iso-egress-bridge.service
    systemctl daemon-reload
    systemctl restart iso-egress-bridge.socket
    if [ -n "$changed" ]; then systemctl try-restart docker; fi
    # Managed proxy lines in /etc/environment; other lines are kept.
    envfile=/etc/environment
    touch "$envfile"
    { grep -v -E '^(http_proxy|https_proxy|HTTP_PROXY|HTTPS_PROXY|no_proxy|NO_PROXY)=' "$envfile" || true
      for k in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; do printf '%s="%s"\n' "$k" "$url"; done
      printf '%s\n' 'no_proxy="localhost,127.0.0.1"' 'NO_PROXY="localhost,127.0.0.1"'
    } > "$envfile.iso"
    chmod 644 "$envfile.iso"
    mv "$envfile.iso" "$envfile"
    # git's default proxy auth probes without credentials and expects a 407;
    # the companion answers every denial with 403.
    if command -v git >/dev/null 2>&1; then
      (umask 022; git config --system http.proxyAuthMethod basic)
      chmod 644 /etc/gitconfig
    fi
    home=$(getent passwd \(user.rawValue) | cut -d: -f6)
    mkdir -p "$home/.docker"
    cfg="$home/.docker/config.json"
    [ -s "$cfg" ] || printf '{}\\n' > "$cfg"
    jq --arg u "$bridge" '.proxies.default = {httpsProxy: $u, httpProxy: $u, noProxy: "localhost,127.0.0.1"}' \\
      "$cfg" > "$cfg.iso"
    mv "$cfg.iso" "$cfg"
    chown -R \(user.rawValue):\(user.rawValue) "$home/.docker"
    chmod 600 "$cfg"
    """
  }

  static func command(port: UInt16, user: GuestUser) -> RemoteCommand {
    RemoteCommand().literal("sudo sh -c ").arg(script(port: port, user: user))
  }

  /// The proxy URL guest sessions already receive (`applyFilteredProxy`).
  static func proxyURL(capability: String, port: UInt16) -> String {
    "http://iso:\(capability)@127.0.0.1:\(port)"
  }
}

extension ProxyLauncher {
  /// Best effort: a guest whose Docker is absent or broken keeps failing its
  /// pulls explicitly at the companion-less default, never another route.
  func configureEgressClients(
    _ target: SSHTarget, port: UInt16, capability: String, user: GuestUser
  ) {
    do {
      try SSHClient(environment: environment).exec(
        target, EgressClients.command(port: port, user: user),
        stdin: Array((EgressClients.proxyURL(capability: capability, port: port) + "\n").utf8))
    } catch {
      diagnostics.warn(
        "Could not point the guest's Docker at the filtered-egress companion; Docker pulls and container egress will fail: \(oneLine(error))"
      )
    }
  }
}
