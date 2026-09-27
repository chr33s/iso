//! Provision the Apple backend's Ubuntu guest image.
use crate::devcontainer_oci::ResolvedFeature;
use crate::guest::{
    BASE_PACKAGES, DOCKER_PACKAGES, GH_PACKAGES, GuestUser, ProfileDef, SCRIPT_CLAUDE_CODE,
    SCRIPT_CODEX, SCRIPT_CODEX_ACCOUNT, SCRIPT_DOCKER_REPO, SCRIPT_GH_REPO,
};

pub(crate) fn compose_provision_script(
    ssh_pubkey: &str,
    profiles: &[ProfileDef],
    oci_features: &[ResolvedFeature],
    guest_user: &GuestUser,
) -> String {
    let mut s = String::with_capacity(8192);

    // Preamble
    s.push_str("#!/bin/bash\n");
    s.push_str("set -euo pipefail\n");
    s.push_str("export DEBIAN_FRONTEND=noninteractive\n");
    s.push_str("export DPKG_OPTIONS='--force-confnew'\n");
    s.push_str("APT_OPTS=(-o Dpkg::Options::=--force-confnew)\n\n");

    // Add all third-party repos first (curl/gpg available on cloud image)
    s.push_str(SCRIPT_GH_REPO);
    s.push('\n');
    s.push_str(SCRIPT_DOCKER_REPO);
    s.push('\n');

    // Collect packages/scripts from already-resolved profiles
    let profile_apt: Vec<&str> = profiles
        .iter()
        .flat_map(|d| d.apt_packages.iter().map(String::as_str))
        .collect();
    let pre_scripts: Vec<&str> = profiles
        .iter()
        .filter_map(|d| d.pre_install.as_deref())
        .collect();
    let post_scripts: Vec<&str> = profiles
        .iter()
        .filter_map(|d| d.post_install.as_deref())
        .collect();

    // Profile pre-scripts (may add repos, e.g. NodeSource)
    for pre in &pre_scripts {
        s.push('\n');
        s.push_str(pre);
        if !pre.ends_with('\n') {
            s.push('\n');
        }
    }

    // Single apt-get update covering all repos
    s.push_str("\necho '  [guest] Updating package lists...'\n");
    s.push_str("apt-get update -qq\n\n");

    // Combine all packages into a single install
    let all_packages: Vec<&str> = BASE_PACKAGES
        .iter()
        .chain(GH_PACKAGES)
        .chain(DOCKER_PACKAGES)
        .copied()
        .chain(profile_apt.iter().copied())
        .collect();

    s.push_str("echo '  [guest] Installing all packages...'\n");
    s.push_str(
        "apt-get install -y -qq \"${APT_OPTS[@]}\" \
         --no-install-recommends \\\n    ",
    );
    s.push_str(&all_packages.join(" "));
    s.push_str(" < /dev/null\n");

    // Profile post-install scripts
    for post in &post_scripts {
        s.push('\n');
        s.push_str(post);
        if !post.ends_with('\n') {
            s.push('\n');
        }
    }

    // Guest configuration configures the guest user — must come before claude-code install
    s.push_str(&compose_guest_config(ssh_pubkey, guest_user));
    for feature in oci_features {
        s.push_str(&crate::devcontainer_oci::compose_install_snippet(feature));
    }

    // Claude Code (direct binary download, runs as root, chowns to claude)
    s.push_str(SCRIPT_CLAUDE_CODE);
    s.push('\n');

    // Codex CLI (native per-user package with a system compatibility link)
    s.push_str(SCRIPT_CODEX);
    s.push('\n');
    s.push_str(SCRIPT_CODEX_ACCOUNT);
    s.push('\n');

    // Test hook: inject a provision failure to exercise error detection.
    // Only activates when COOP_TEST_INJECT_PROVISION_FAILURE is set.
    if std::env::var("COOP_TEST_INJECT_PROVISION_FAILURE").is_ok() {
        s.push_str("\necho '  [guest] INJECTED FAILURE FOR TESTING'\n");
        s.push_str("exit 1\n");
    }

    // Cleanup
    s.push_str("\necho '  [guest] Cleaning up...'\n");
    s.push_str("apt-get clean\n");
    s.push_str("rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*\n");
    s.push_str("\necho '  [guest] Provisioning complete'\n");

    s
}

fn compose_guest_config(ssh_pubkey: &str, guest_user: &GuestUser) -> String {
    // GuestUser::new validated the name against POSIX-portable chars, so
    // it's safe to interpolate into the shell script body and a single-
    // quoted export at the top of the recipe.
    let user = guest_user.as_str();
    let home = guest_user.home();
    format!(
        r#"
export GUEST_USER='{user}'

echo "  [guest] Ensuring {user} user exists (uid 1000)..."
if id "{user}" &>/dev/null; then
    usermod -aG sudo,docker "{user}"
else
    # Remove any other user occupying uid 1000 (e.g. the base image’s `ubuntu` user) so our configured guest user takes
    # over uid 1000 cleanly.
    EXISTING=$(getent passwd 1000 | cut -d: -f1) || true
    if [[ -n "$EXISTING" ]]; then
        userdel "$EXISTING"
    fi
    useradd -m -s /bin/bash --uid 1000 -G sudo,docker "{user}"
fi
echo "{user} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/{user}"
chmod 440 "/etc/sudoers.d/{user}"

echo "  [guest] Setting up home and SSH for {user} user..."
mkdir -p "{home}"
chown "{user}:{user}" "{home}"
chmod 755 "{home}"
install -d -o "{user}" -g "{user}" "{home}/.local"
install -d -o "{user}" -g "{user}" "{home}/.local/bin"
install -d -o "{user}" -g "{user}" "{home}/.local/share"
mkdir -p "{home}/.ssh"
echo '{ssh_pubkey}' > "{home}/.ssh/authorized_keys"
chown -R "{user}:{user}" "{home}/.ssh"
chmod 700 "{home}/.ssh"
chmod 600 "{home}/.ssh/authorized_keys"

echo "  [guest] Adding {user} ~/.local/bin to /etc/environment PATH..."
# pam_env reads /etc/environment for every SSH session — login, non-login,
# and non-interactive (`ssh host cmd`) alike — so this is the one layer that
# reaches `coop claude` (a remote command), its Bash-tool subshells, and VS
# Code remote sessions. The .profile/.bashrc appends did not: .profile is
# login-only and the .bashrc line sat below Ubuntu's non-interactive guard.
# pam_env does no variable expansion, so the home path is baked in literally.
#
# /etc/environment is system-wide, so this prepends the guest user's writable
# ~/.local/bin to PATH for every account, including root. That's safe here:
# sudo keeps Ubuntu's default secure_path (we set no override), so it ignores
# ~/.local/bin, and the guest is a single-user dev VM where that user already
# has passwordless root — there is no privilege boundary to cross.
if ! grep -q '^PATH="{home}/.local/bin:' /etc/environment 2>/dev/null; then
    if grep -q '^PATH="' /etc/environment 2>/dev/null; then
        sed -i 's|^PATH="|PATH="{home}/.local/bin:|' /etc/environment
    else
        echo 'PATH="{home}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games"' >> /etc/environment
    fi
fi

echo '  [guest] Symlinking claude into system PATH...'
ln -sf "{home}/.local/bin/claude" /usr/local/bin/claude

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
chown "{user}:{user}" /workspace

# No iptables-legacy or NO_IPTABLES_RAW needed — the Apple runtime uses a full kernel with
# nftables and iptable_raw support. These workarounds are Firecracker-only
# (see scripts/guest/guest-config.sh and docs/platform-notes.md).

echo '  [guest] Enabling services...'
systemctl enable docker ssh

echo '  [guest] Configuring SSH daemon...'
sed -i 's/#PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

echo '  [guest] Configuring SSH env forwarding...'
echo 'AcceptEnv *' >> /etc/ssh/sshd_config
"#
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    fn profile(name: &str, apt: &[&str], pre: Option<&str>, post: Option<&str>) -> ProfileDef {
        ProfileDef {
            name: name.into(),
            apt_packages: apt.iter().map(|s| (*s).into()).collect(),
            pre_install: pre.map(Into::into),
            post_install: post.map(Into::into),
            marketplaces: Vec::new(),
            plugins: Vec::new(),
        }
    }

    fn no_consecutive_concat(script: &str) {
        for (i, line) in script.lines().enumerate() {
            assert!(
                !line.contains("set -euo pipefail") || line.trim() == "set -euo pipefail",
                "line {}: 'set -euo pipefail' concatenated with other content: {line}",
                i + 1,
            );
        }
    }

    #[test]
    fn provision_script_sets_path_via_etc_environment() {
        let script = compose_provision_script(
            "ssh-ed25519 AAAA test@test",
            &[],
            &[],
            &GuestUser::default(),
        );

        // PATH is set in /etc/environment (pam_env applies it to every SSH
        // session), with the guest home interpolated as a literal path.
        assert!(
            script
                .contains("sed -i 's|^PATH=\"|PATH=\"/home/ubuntu/.local/bin:|' /etc/environment"),
            "should prepend ~/.local/bin to /etc/environment PATH",
        );
        // The old PATH appends to .profile/.bashrc are gone (see issue #248).
        assert!(
            !script.contains(">> \"/home/ubuntu/.profile\"")
                && !script.contains(">> \"/home/ubuntu/.bashrc\""),
            "should no longer append PATH to .profile/.bashrc",
        );
    }

    #[test]
    fn provision_script_post_install_without_trailing_newline() {
        let profiles = vec![profile("test", &["curl"], None, Some("echo done"))];
        let script = compose_provision_script(
            "ssh-ed25519 AAAA test@test",
            &profiles,
            &[],
            &GuestUser::default(),
        );

        assert!(
            script.contains("echo done\n"),
            "post_install should end with newline",
        );
        no_consecutive_concat(&script);
    }

    #[test]
    fn provision_script_pre_install_without_trailing_newline() {
        let profiles = vec![profile(
            "test",
            &[],
            Some("curl -fsSL https://example.com | bash"),
            None,
        )];
        let script = compose_provision_script(
            "ssh-ed25519 AAAA test@test",
            &profiles,
            &[],
            &GuestUser::default(),
        );

        assert!(
            script.contains("| bash\n"),
            "pre_install should end with newline",
        );
        no_consecutive_concat(&script);
    }

    #[test]
    fn provision_script_multiple_profiles_separated() {
        let profiles = vec![
            profile("a", &[], None, Some("echo a-done")),
            profile("b", &[], None, Some("echo b-done")),
        ];
        let script = compose_provision_script(
            "ssh-ed25519 AAAA test@test",
            &profiles,
            &[],
            &GuestUser::default(),
        );

        assert!(script.contains("echo a-done\n"));
        assert!(script.contains("echo b-done\n"));
        for line in script.lines() {
            assert!(
                !(line.contains("a-done") && line.contains("b-done")),
                "two post_install scripts concatenated on one line",
            );
        }
    }

    #[test]
    fn provision_script_installs_codex() {
        let script = compose_provision_script(
            "ssh-ed25519 AAAA test@test",
            &[],
            &[],
            &GuestUser::default(),
        );

        assert!(
            script.contains("Installing Codex CLI"),
            "Apple provision script should install Codex CLI",
        );
        assert!(
            script.contains("Installing codex-account shortcut"),
            "Apple provision script should install Codex account-auth wrapper",
        );
        assert!(
            script.contains("exec codex-account --dangerously-bypass-approvals-and-sandbox"),
            "codex-yolo should route through the account wrapper so keyring \
             mode works from an in-guest shell",
        );
    }

    // ── inject_mounts ───────────────────────────────────────────
}
