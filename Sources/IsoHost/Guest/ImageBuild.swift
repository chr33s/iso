// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import IsoConfiguration
import IsoCore

/// `images/<name>/apple-image.json`, published only after the image passed
/// verification in a disposable sandbox (or was committed from an instance).
package struct ImageManifest: Sendable, Equatable, Codable {
  package let schemaVersion: UInt32
  package let backend: String
  /// Owned local tag, e.g. `local/iso-0a1b2c3d:0011223344556677-1a2b3c4d`.
  /// For a committed disk, the image the committed instance was created from.
  package let imageRef: String
  package let digest: String
  /// Set for an image made by `iso commit`: instances clone this disk.
  package let disk: CommittedDisk?
  package let manifestID: String
  package let baseImage: String
  package let platform: String
  package let guestUser: GuestUser
  package let created: String

  enum CodingKeys: String, CodingKey {
    case backend, digest, disk, platform, created
    case schemaVersion = "schema_version"
    case imageRef = "image_ref"
    case manifestID = "manifest_id"
    case baseImage = "base_image"
    case guestUser = "guest_user"
  }

  package func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(schemaVersion, forKey: .schemaVersion)
    try c.encode(backend, forKey: .backend)
    try c.encode(imageRef, forKey: .imageRef)
    try c.encode(digest, forKey: .digest)
    try c.encode(disk, forKey: .disk)
    try c.encode(manifestID, forKey: .manifestID)
    try c.encode(baseImage, forKey: .baseImage)
    try c.encode(platform, forKey: .platform)
    try c.encode(guestUser, forKey: .guestUser)
    try c.encode(created, forKey: .created)
  }

  package struct CommittedDisk: Sendable, Equatable, Codable {
    package let name: MachineName
    package let bytes: UInt64
  }

  package static func path(_ config: IsoConfig, _ image: ImageName) -> String {
    config.imagesDirectory.appending(image.rawValue).appending("apple-image.json").path
  }

  /// Nil when absent; a foreign or other-schema manifest is refused.
  package static func loadIfPresent(_ config: IsoConfig, _ image: ImageName) throws
    -> ImageManifest?
  {
    let path = path(config, image)
    guard let data = FileManager.default.contents(atPath: path) else {
      if FileManager.default.fileExists(atPath: path) { throw HostError("Failed to read \(path)") }
      return nil
    }
    let manifest = try StateStore.decode(ImageManifest.self, Array(data), path: path)
    guard manifest.backend == StateSchema.backend, manifest.schemaVersion == StateSchema.version
    else {
      throw RuntimeError.identityConflict(
        "\(path) is not a \(StateSchema.backend) v\(StateSchema.version) image manifest")
    }
    return manifest
  }

  package static func load(_ config: IsoConfig, _ image: ImageName) throws -> ImageManifest {
    guard let manifest = try loadIfPresent(config, image) else {
      throw HostError("No image '\(image)' found.\nRun `iso setup --image \(image)` first.")
    }
    return manifest
  }

  /// For paths that replace or remove a manifest: unreadable means absent.
  package static func loadLenient(_ config: IsoConfig, _ image: ImageName, diagnostics: Diagnostics)
    -> ImageManifest?
  {
    do { return try loadIfPresent(config, image) } catch {
      diagnostics.warn("Ignoring unreadable image manifest for '\(image)': \(oneLine(error))")
      return nil
    }
  }

  package func save(_ config: IsoConfig, _ image: ImageName) throws {
    try StateStore.ensurePrivateDirectory(config.imagesDirectory.appending(image.rawValue).path)
    try StateStore.writeControlFile(self, to: Self.path(config, image))
  }
}

/// anyhow `{:#}`-style single line for any error.
package func oneLine(_ error: any Error) -> String {
  error.contextError?.alternate ?? "\(error)"
}

/// The generated build context: only a Dockerfile and reviewed provisioning
/// scripts, including the VM-access public key. Never a repository, the
/// working directory, or the home directory, and never a secret. Its contents
/// and identity inputs determine the image manifest hash.
package struct BuildContext: Sendable, Equatable {
  package static let baseImage =
    "docker.io/library/ubuntu:24.04@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3"
  package static let platform = "linux/arm64"
  static let contextDirectory = "/opt/iso-build"
  package static let maintenanceVersion = "2"

  package let files: [(name: String, content: String, mode: UInt32)]

  package static func == (a: Self, b: Self) -> Bool {
    a.files.count == b.files.count
      && zip(a.files, b.files).allSatisfy {
        $0.name == $1.name && $0.content == $1.content && $0.mode == $1.mode
      }
  }

  package static func render(
    publicKey: String, profiles: [ProfileDefinition], guestUser: GuestUser,
    ociFeatures: [ResolvedFeature] = []
  ) -> BuildContext {
    BuildContext(files: [
      ("Dockerfile", dockerfile, 0o644),
      (
        "provision.sh",
        Provisioning.script(
          publicKey: publicKey, profiles: profiles, guestUser: guestUser, ociFeatures: ociFeatures),
        0o644
      ),
      ("machine-setup.sh", machineSetup, 0o644),
      ("iso-ssh-hostkeys.service", hostKeyUnit, 0o644),
      ("10-iso.conf", sshdDropIn, 0o644),
    ])
  }

  /// Stable hash of the context plus identity inputs not in file contents.
  package func manifestID(guestUser: GuestUser, publicKeyFingerprint: String) -> String {
    var hash = SHA256()
    for part in [
      "schema=\(StateSchema.version)", "base=\(Self.baseImage)", "platform=\(Self.platform)",
      "user=\(guestUser)",
      "pubkey=\(publicKeyFingerprint)",
    ] {
      hash.update(data: Data(part.utf8))
      hash.update(data: Data([0]))
    }
    for file in files {
      hash.update(data: Data(file.name.utf8))
      hash.update(data: Data([0]))
      withUnsafeBytes(of: file.mode.bigEndian) { hash.update(bufferPointer: $0) }
      hash.update(data: Data(file.content.utf8))
      hash.update(data: Data([0]))
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  package func materialize(prefix: String = "iso-apple-build-") throws -> TemporaryDirectory {
    let directory = try TemporaryDirectory(prefix: prefix)
    for file in files {
      let path = directory.path + "/" + file.name
      try AtomicFile.createExclusive(Array(file.content.utf8), at: path, mode: mode_t(file.mode))
    }
    return directory
  }

  package static let maintenanceDockerfile = """
    # Generated by iso — iso-sandbox maintenance image \(maintenanceVersion).
    FROM \(baseImage)
    RUN set -eux; \\
        export DEBIAN_FRONTEND=noninteractive; \\
        apt-get update -qq; \\
        apt-get install -y -qq --no-install-recommends e2fsprogs; \\
        rm -rf /var/lib/apt/lists/*

    """

  package static func maintenanceContext() throws -> TemporaryDirectory {
    let directory = try TemporaryDirectory(prefix: "iso-apple-maintenance-")
    try AtomicFile.createExclusive(
      Array(maintenanceDockerfile.utf8), at: directory.path + "/Dockerfile", mode: 0o644)
    return directory
  }

  /// `local/iso-<owner8>:`, the repository prefix of every owned image tag.
  package static func ownedRepository(_ owner: OwnerID) -> String { "local/iso-\(owner.short):" }

  /// Fresh tag per build: content hash prefix plus a nonce, so a rebuild
  /// never retags an image a manifest or instance points at.
  package static func imageRef(owner: OwnerID, manifestID: String, buildID: String) -> String {
    ownedRepository(owner) + String(manifestID.prefix(16)) + "-" + buildID
  }

  package static func maintenanceRef(owner: OwnerID, buildID: String) -> String {
    "local/iso-\(owner.short)-maintenance:\(maintenanceVersion)-\(buildID)"
  }

  static let dockerfile = """
    # Generated by iso — iso-sandbox image.
    FROM \(baseImage)
    ENV container=container
    COPY . \(contextDirectory)/
    RUN set -eux; \\
        export DEBIAN_FRONTEND=noninteractive; \\
        apt-get \(Provisioning.aptNetworkOptions) update; \\
        apt-get \(Provisioning.aptNetworkOptions) install -y --no-install-recommends \\
            ca-certificates curl gnupg systemd systemd-sysv dbus openssh-server sudo \\
            iproute2 iputils-ping lsb-release e2fsprogs; \\
        bash \(contextDirectory)/provision.sh; \\
        bash \(contextDirectory)/machine-setup.sh; \\
        rm -rf \(contextDirectory)

    """

  static let machineSetup = """
    #!/bin/bash
    set -euo pipefail

    systemctl set-default multi-user.target
    systemctl mask \\
        systemd-udevd.service systemd-udevd-kernel.socket systemd-udevd-control.socket \\
        systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service \\
        systemd-resolved.service systemd-timesyncd.service systemd-firstboot.service \\
        getty.target console-getty.service
    systemctl disable networkd-dispatcher.service 2>/dev/null || true

    install -m 0644 \(contextDirectory)/iso-ssh-hostkeys.service /etc/systemd/system/iso-ssh-hostkeys.service
    install -d -m 0755 /etc/ssh/sshd_config.d
    install -m 0644 \(contextDirectory)/10-iso.conf /etc/ssh/sshd_config.d/10-iso.conf
    systemctl disable ssh.socket 2>/dev/null || true
    systemctl enable iso-ssh-hostkeys.service ssh.service docker.service

    rm -f /etc/ssh/ssh_host_*
    : > /etc/machine-id
    rm -f /var/lib/dbus/machine-id

    """

  static let hostKeyUnit = """
    [Unit]
    Description=Generate this machine's SSH host keys
    Before=ssh.service
    ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key

    [Service]
    Type=oneshot
    ExecStart=/usr/bin/ssh-keygen -A

    [Install]
    WantedBy=multi-user.target

    """

  /// Included before the main `sshd_config`, so these values win.
  static let sshdDropIn = """
    PermitRootLogin no
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PubkeyAuthentication yes
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    X11Forwarding no
    PermitTunnel no
    GatewayPorts no
    AllowTcpForwarding yes

    """
}

package final class TemporaryDirectory: Sendable {
  package let path: String

  package init(prefix: String) throws(HostError) {
    let template = (NSTemporaryDirectory() as NSString).appendingPathComponent(prefix + "XXXXXX")
    var bytes = Array(template.utf8CString)
    guard mkdtemp(&bytes) != nil else { throw .posix("Failed to create", template) }
    path = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    chmod(path, 0o700)
  }

  package func remove() { try? FileManager.default.removeItem(atPath: path) }
  deinit { remove() }
}

package enum Provisioning {
  // Bound stalled repository reads without extending the overall image-build deadline.
  static let aptNetworkOptions =
    "-o Acquire::Retries=2 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30"

  package static let basePackages = [
    "openssh-server", "dbus-user-session", "curl", "wget", "git", "build-essential",
    "ca-certificates", "gnupg",
    "lsb-release", "sudo", "iproute2", "iptables", "kmod", "procps", "util-linux", "jq", "rsync",
    "unzip", "zip",
    "file", "gnome-keyring", "less", "libsecret-tools",
  ]
  package static let ghPackages = ["gh"]
  package static let dockerPackages = [
    "docker-ce", "docker-ce-cli", "containerd.io", "docker-buildx-plugin", "docker-compose-plugin",
  ]

  package static func script(
    publicKey: String, profiles: [ProfileDefinition], guestUser: GuestUser,
    ociFeatures: [ResolvedFeature] = []
  ) -> String {
    var s = "#!/bin/bash\n"
    s += "set -euo pipefail\n"
    s += "export DEBIAN_FRONTEND=noninteractive\n"
    s += "export DPKG_OPTIONS='--force-confnew'\n"
    s += "APT_OPTS=(\(aptNetworkOptions) -o Dpkg::Options::=--force-confnew)\n\n"
    s += EmbeddedResources.guestScript("gh-cli-repo.sh") + "\n"
    s += EmbeddedResources.guestScript("docker-repo.sh") + "\n"
    for pre in profiles.compactMap(\.preInstall) {
      s += "\n" + pre + (pre.hasSuffix("\n") ? "" : "\n")
    }
    s += "\necho '  [guest] Updating package lists...'\n"
    s += "apt-get \"${APT_OPTS[@]}\" update\n\n"
    let packages = basePackages + ghPackages + dockerPackages + profiles.flatMap(\.aptPackages)
    s += "echo '  [guest] Installing all packages...'\n"
    s += "apt-get \"${APT_OPTS[@]}\" install -y --no-install-recommends \\\n    "
    s += packages.joined(separator: " ") + " < /dev/null\n"
    for post in profiles.compactMap(\.postInstall) {
      s += "\n" + post + (post.hasSuffix("\n") ? "" : "\n")
    }
    s += guestConfig(publicKey: publicKey, guestUser: guestUser)
    for feature in ociFeatures { s += feature.installSnippet }
    s += EmbeddedResources.guestScript("claude-code.sh") + "\n"
    s += EmbeddedResources.guestScript("codex.sh") + "\n"
    s += EmbeddedResources.guestScript("codex-account.sh") + "\n"
    s += "\necho '  [guest] Cleaning up...'\n"
    s += "apt-get clean\n"
    s += "rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*\n"
    s += "\necho '  [guest] Provisioning complete'\n"
    return s
  }

  static func guestConfig(publicKey key: String, guestUser: GuestUser) -> String {
    let user = guestUser.rawValue
    let home = guestUser.home
    return """

      export GUEST_USER='\(user)'

      echo "  [guest] Ensuring \(user) user exists (uid 1000)..."
      if id "\(user)" &>/dev/null; then
          usermod -aG sudo,docker "\(user)"
      else
          # Remove any other user occupying uid 1000 (e.g. the base image’s `ubuntu` user) so our configured guest user takes
          # over uid 1000 cleanly.
          EXISTING=$(getent passwd 1000 | cut -d: -f1) || true
          if [[ -n "$EXISTING" ]]; then
              userdel "$EXISTING"
          fi
          useradd -m -s /bin/bash --uid 1000 -G sudo,docker "\(user)"
      fi
      echo "\(user) ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/\(user)"
      chmod 440 "/etc/sudoers.d/\(user)"

      echo "  [guest] Setting up home and SSH for \(user) user..."
      mkdir -p "\(home)"
      chown "\(user):\(user)" "\(home)"
      chmod 755 "\(home)"
      install -d -o "\(user)" -g "\(user)" "\(home)/.local"
      install -d -o "\(user)" -g "\(user)" "\(home)/.local/bin"
      install -d -o "\(user)" -g "\(user)" "\(home)/.local/share"
      mkdir -p "\(home)/.ssh"
      echo '\(key)' > "\(home)/.ssh/authorized_keys"
      chown -R "\(user):\(user)" "\(home)/.ssh"
      chmod 700 "\(home)/.ssh"
      chmod 600 "\(home)/.ssh/authorized_keys"

      echo "  [guest] Adding \(user) ~/.local/bin to /etc/environment PATH..."
      # pam_env reads /etc/environment for every SSH session — login, non-login,
      # and non-interactive (`ssh host cmd`) alike — so this is the one layer that
      # reaches `iso claude` (a remote command), its Bash-tool subshells, and VS
      # Code remote sessions. The .profile/.bashrc appends did not: .profile is
      # login-only and the .bashrc line sat below Ubuntu's non-interactive guard.
      # pam_env does no variable expansion, so the home path is baked in literally.
      #
      # /etc/environment is system-wide, so this prepends the guest user's writable
      # ~/.local/bin to PATH for every account, including root. That's safe here:
      # sudo keeps Ubuntu's default secure_path (we set no override), so it ignores
      # ~/.local/bin, and the guest is a single-user dev VM where that user already
      # has passwordless root — there is no privilege boundary to cross.
      if ! grep -q '^PATH="\(home)/.local/bin:' /etc/environment 2>/dev/null; then
          if grep -q '^PATH="' /etc/environment 2>/dev/null; then
              sed -i 's|^PATH="|PATH="\(home)/.local/bin:|' /etc/environment
          else
              echo 'PATH="\(home)/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games"' >> /etc/environment
          fi
      fi

      echo '  [guest] Symlinking claude into system PATH...'
      ln -sf "\(home)/.local/bin/claude" /usr/local/bin/claude

      echo '  [guest] Installing claude-yolo shortcut...'
      cat > /usr/local/bin/claude-yolo <<'YOLOEOF'
      #!/bin/bash
      exec claude --dangerously-skip-permissions "$@"
      YOLOEOF
      chmod 755 /usr/local/bin/claude-yolo

      echo '  [guest] Installing codex-yolo shortcut...'
      cat > /usr/local/bin/codex-yolo <<'YOLOEOF'
      #!/bin/bash
      exec codex-account --dangerously-bypass-approvals-and-sandbox "$@"
      YOLOEOF
      chmod 755 /usr/local/bin/codex-yolo

      echo '  [guest] Preparing workspace directory...'
      mkdir -p /workspace
      chown "\(user):\(user)" /workspace

      # No iptables-legacy or NO_IPTABLES_RAW needed — the Apple runtime uses a full kernel with
      # nftables and iptable_raw support (see docs/platform-notes.md).

      echo '  [guest] Enabling services...'
      systemctl enable docker ssh

      echo '  [guest] Configuring SSH daemon...'
      sed -i 's/#PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
      sed -i 's/#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

      echo '  [guest] Configuring SSH env forwarding...'
      echo 'AcceptEnv *' >> /etc/ssh/sshd_config

      """
  }
}
