# Derived from trailofbits/coop.
# Modified by chr33s: ported/adapted for the Swift implementation.
# SPDX-License-Identifier: Apache-2.0

# shellcheck shell=bash
set -euo pipefail

echo '  [guest] Installing codex-account shortcut...'
cat >/usr/local/bin/codex-account <<'CODEXACCOUNTEOF'
#!/usr/bin/env bash
set -euo pipefail

CODEX_BIN="/usr/local/bin/codex"
CODEX_CONFIG="${CODEX_HOME:-$HOME/.codex}/config.toml"
KEYRING_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/keyrings"
PROBE_SERVICE="iso-codex"
PROBE_ACCOUNT="keyring-probe"

die() {
    echo "codex-account: $*" >&2
    exit 1
}

# Only `[codex] auth = "chatgpt"` makes iso write `cli_auth_credentials_store = "keyring"`;
# every other mode reads auth.json, where the keyring session is pure overhead. Gating on the
# guest's actual config lets every Codex entry point route through this wrapper.
keyring_mode_in() {
    local config=$1
    local first_line=""
    [ -r "$config" ] \
        && IFS= read -r first_line < "$config" \
        && [ "$first_line" = 'cli_auth_credentials_store = "keyring"' ]
}

keyring_mode() {
    keyring_mode_in "$CODEX_CONFIG"
}

keyring_exists() {
    compgen -G "$KEYRING_DIR/*.keyring" >/dev/null 2>&1
}

# secret-tool's stderr from the last probe, so the failure path reports the real cause.
PROBE_ERROR=""

# Writing proves the collection is reachable and unlocked (a lookup can succeed against a locked
# one); the probe item is cleared so repeated launches do not accumulate junk.
probe_keyring() {
    PROBE_ERROR="$(printf 'ok' \
        | timeout 5 secret-tool store \
            --label="iso Codex keyring probe" \
            service "$PROBE_SERVICE" \
            account "$PROBE_ACCOUNT" \
            2>&1 >/dev/null)" || return 1
    timeout 5 secret-tool clear \
        service "$PROBE_SERVICE" \
        account "$PROBE_ACCOUNT" \
        >/dev/null 2>&1 || true
}

unlock_keyring() {
    local creating=0 password confirm output
    keyring_exists || creating=1

    if [ ! -t 0 ]; then
        die "Codex ChatGPT auth needs an interactive TTY to unlock the guest keyring"
    fi

    # On a fresh guest this prompt chooses a password; confirm it, since a typo would lock the
    # credentials behind a password the user cannot reproduce.
    if [ "$creating" = 1 ]; then
        printf '%s\n' \
            'codex-account: this VM has no guest keyring yet.' \
            'Choose a password to create one. It encrypts the Codex account' \
            'credentials stored inside the guest, and later `iso codex` runs' \
            'ask for it again. It is not your ChatGPT or host password.' >&2
    fi

    if ! IFS= read -rsp "Codex keyring password: " password; then
        echo >&2
        die "failed to read keyring password"
    fi
    echo >&2

    if [ -z "$password" ]; then
        die "keyring password must not be empty"
    fi

    if [ "$creating" = 1 ]; then
        if ! IFS= read -rsp "Confirm keyring password: " confirm; then
            echo >&2
            die "failed to read keyring password"
        fi
        echo >&2
        if [ "$password" != "$confirm" ]; then
            die "passwords did not match; no keyring was created"
        fi
    fi

    # Daemon stderr reaches the terminal (startup diagnostics only; the probe reports a wrong password).
    output="$(printf '%s' "$password" \
        | timeout 30 gnome-keyring-daemon --unlock --components=secrets)" \
        || die "failed to unlock the guest keyring"

    # Take only `NAME=value` lines and export them: an unfiltered `eval` would execute any GLib
    # diagnostic on stdout as a command.
    while IFS= read -r line; do
        case "$line" in
            [A-Za-z_]*=*) export "${line%%=*}=${line#*=}" ;;
        esac
    done <<<"$output"
}

if [ ! -x "$CODEX_BIN" ]; then
    die "$CODEX_BIN is missing; rebuild the iso image"
fi

# iso manages Codex state only in ~/.codex. An explicit CODEX_HOME could put auth.json outside
# iso's cleanup path (including /workspace, which is pulled back to the host), so refuse it.
# iso writes the managed credential-store key first, so a nested same-named key cannot trigger this.
if [ -n "${CODEX_HOME:-}" ] \
    && keyring_mode_in "$HOME/.codex/config.toml"; then
    die "CODEX_HOME is set, but iso manages ~/.codex and it selects the keyring credential store; unset CODEX_HOME for Codex ChatGPT account auth"
fi

if ! keyring_mode; then
    exec "$CODEX_BIN" "$@"
fi

# Keyring needs a D-Bus session bus; re-exec under one (env guard prevents recursion).
if [ "${ISO_CODEX_ACCOUNT_DBUS:-0}" != "1" ]; then
    command -v dbus-run-session >/dev/null 2>&1 \
        || die "dbus-run-session is missing; install dbus-user-session or rebuild the iso image"
    export ISO_CODEX_ACCOUNT_DBUS=1
    exec dbus-run-session -- "$0" "$@"
fi

for tool in gnome-keyring-daemon secret-tool timeout; do
    command -v "$tool" >/dev/null 2>&1 \
        || die "$tool is missing; rebuild the iso image with Codex account-auth support"
done

# A nested codex-account (in-guest agent) inherits this bus and its unlocked keyring; unlocking
# again would fail, so reuse the session.
if [ "${ISO_CODEX_ACCOUNT_UNLOCKED:-0}" = "1" ]; then
    probe_keyring \
        || die "inherited guest Secret Service session is unusable${PROBE_ERROR:+: $PROBE_ERROR}"
else
    # Unlock before anything else touches the bus: `gnome-keyring-daemon --unlock` only creates and
    # unlocks the login collection when it starts the daemon; once any daemon owns
    # `org.freedesktop.secrets` (even one the probe would D-Bus-activate) it defers to the graphical
    # gcr-prompter, which cannot render headless.
    unlock_keyring
    probe_keyring \
        || die "guest Secret Service is unavailable${PROBE_ERROR:+: $PROBE_ERROR}; check the keyring password"
    export ISO_CODEX_ACCOUNT_UNLOCKED=1
fi

# Codex 0.154.0 can reuse a desktop daemon on another D-Bus session without explicit config
# overrides; pin it to the keyring just unlocked. Prepended so caller overrides win.
exec "$CODEX_BIN" -c 'cli_auth_credentials_store="keyring"' "$@"
CODEXACCOUNTEOF
chmod 755 /usr/local/bin/codex-account
