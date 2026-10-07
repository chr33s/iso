import Foundation
import IsoCore

/// The root script `iso setup --guest macos` gives `iso-sandbox macos
/// template build --provision`. It makes the macOS guest present the paths
/// and conventions iso's guest commands already use on Linux, and installs
/// the agents from the same upstream installers as the Linux image.
package enum MacProvision {
  /// The account `iso-sandbox` provisions in every macOS template.
  package static let guestUser = try! GuestUser("iso")
  /// GitHub CLI release pinned by checksum, as the Linux image pins its apt
  /// repository key.
  static let ghVersion = "2.102.0"
  static let ghSHA256 = "da922c20d1792e5b2cbf375593d7a658acf034c12c84e007e71c76ef959c337e"

  package static func script() -> String {
    """
    #!/bin/bash
    set -euo pipefail
    log() { printf '  [guest] %s\\n' "$*"; }

    # Linux-compatible layout. /workspace is a root symlink (synthetic.conf;
    # the system volume is sealed) to a directory the guest user owns, and
    # /home/iso resolves to the account's real home: with the auto_home
    # automount disabled, /home exists only through synthetic.conf. A group
    # named after the user makes `chown iso:iso` work.
    log 'Preparing /workspace, /home/iso and the iso group'
    install -d -o iso -g staff -m 0755 /Users/iso/workspace
    grep -q '^workspace' /etc/synthetic.conf 2>/dev/null \\
      || printf 'workspace\\tUsers/iso/workspace\\n' >> /etc/synthetic.conf
    grep -q '^home' /etc/synthetic.conf \\
      || printf 'home\\tSystem/Volumes/Data/home\\n' >> /etc/synthetic.conf
    chmod 0644 /etc/synthetic.conf
    sed -i '' -e 's|^/home[[:space:]]|#&|' /etc/auto_master
    automount -vc >/dev/null 2>&1 || true
    umount /System/Volumes/Data/home >/dev/null 2>&1 || true
    install -d -o root -g wheel -m 0755 /System/Volumes/Data/home
    ln -sfh /Users/iso /System/Volumes/Data/home/iso
    dseditgroup -o read iso >/dev/null 2>&1 || dseditgroup -o create -r iso iso
    dseditgroup -o edit -a iso -t user iso

    # Commands over SSH run `zsh -c`, which reads /etc/zshenv: the same
    # PATH a Linux guest's /etc/environment gives.
    cat > /etc/zshenv <<'ZSHENV'
    export PATH="/home/iso/.local/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
    ZSHENV
    chmod 0644 /etc/zshenv

    # The host forwards provider and proxy settings with SendEnv, as for Linux.
    printf 'AcceptEnv *\\n' > /etc/ssh/sshd_config.d/050-iso-env.conf
    chmod 0644 /etc/ssh/sshd_config.d/050-iso-env.conf

    # timeout(1) is not part of macOS; iso's guest commands use it.
    install -d -m 0755 /usr/local/bin
    cat > /usr/local/bin/timeout <<'TIMEOUT'
    #!/bin/sh
    # timeout SECONDS COMMAND [ARG...]: SIGALRM ends COMMAND after SECONDS.
    exec /usr/bin/perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$@"
    TIMEOUT
    chmod 0755 /usr/local/bin/timeout

    # git (Command Line Tools), as softwareupdate offers them for this build.
    # The catalog can lag a fresh install's first boot, so it is retried;
    # without git the template is not usable for agents.
    log 'Installing the Command Line Tools'
    touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    clt=
    xcode-select -p >/dev/null 2>&1 && /usr/bin/xcrun --find git >/dev/null 2>&1 && clt=installed
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      [ -n "$clt" ] && break
      clt=$(softwareupdate -l 2>/dev/null | sed -n 's/^[[:space:]]*\\* Label: //p' \\
        | grep 'Command Line Tools' | sort -V | tail -n 1 || true)
      [ -n "$clt" ] && break
      log "softwareupdate offers no Command Line Tools yet (attempt $attempt); retrying"
      sleep 30
    done
    if [ -z "$clt" ]; then
      echo 'softwareupdate offers no Command Line Tools for this macOS build; git is required' >&2
      exit 1
    fi
    [ "$clt" = installed ] || softwareupdate -i "$clt" >/dev/null
    rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    /usr/bin/xcrun --find git >/dev/null

    log 'Installing the GitHub CLI \(ghVersion)'
    gh_zip=$(mktemp -d)/gh.zip
    curl -fsSL --retry 3 -o "$gh_zip" \\
      https://github.com/cli/cli/releases/download/v\(ghVersion)/gh_\(ghVersion)_macOS_arm64.zip
    echo '\(ghSHA256)  '"$gh_zip" | shasum -a 256 -c - >/dev/null
    ditto -x -k "$gh_zip" "$(dirname "$gh_zip")"
    install -m 0755 "$(dirname "$gh_zip")/gh_\(ghVersion)_macOS_arm64/bin/gh" /usr/local/bin/gh
    rm -rf "$(dirname "$gh_zip")"

    log 'Installing Claude Code'
    installer=$(mktemp /tmp/iso-installer.XXXXXX)
    chmod 0644 "$installer"
    curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 -o "$installer" https://claude.ai/install.sh
    su - iso -c "bash '$installer'" </dev/null
    rm -f "$installer"
    test -x /Users/iso/.local/bin/claude

    log 'Installing Codex'
    installer=$(mktemp /tmp/iso-installer.XXXXXX)
    chmod 0644 "$installer"
    curl -fsSL --retry 3 -o "$installer" https://chatgpt.com/codex/install.sh
    su - iso -c "PATH='/Users/iso/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin' CODEX_NON_INTERACTIVE=1 sh '$installer'" </dev/null
    rm -f "$installer"
    ln -sfh /Users/iso/.local/bin/codex /usr/local/bin/codex
    su - iso -c '/usr/local/bin/codex --version' </dev/null
    log 'Provisioning finished'
    """
  }
}
