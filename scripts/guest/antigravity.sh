# Linux image build only: macOS guests install through MacProvision, and
# `iso agent update --antigravity` runs `agy update` in the guest.
# Keep the installer cleanup local when provisioning snippets are concatenated.
(
    set -euo pipefail
    : "${GUEST_USER:?GUEST_USER must be set by the orchestrator}"

    # Profiles may supply their own agy.
    if [ -x /usr/local/bin/agy ]; then
        echo '  [guest] Antigravity CLI already installed, skipping.'
        exit 0
    fi

    echo '  [guest] Installing Antigravity CLI with the native installer...'
    AGY_NATIVE_BIN="/home/${GUEST_USER}/.local/bin/agy"
    AGY_INSTALLER=$(mktemp)
    AGY_LINK_TMP="/usr/local/bin/agy.new.$$"
    trap 'rm -f "$AGY_INSTALLER" "$AGY_LINK_TMP"' EXIT
    chmod 0644 "$AGY_INSTALLER"

    # curl retries transient failures without running a partial script.
    curl -fsSL --retry 3 --retry-all-errors \
        -o "$AGY_INSTALLER" https://antigravity.google/cli/install.sh

    # The installer verifies the download's SHA-512 against its release
    # manifest and installs into the guest user's ~/.local/bin.
    su - "$GUEST_USER" -c \
        "PATH='/home/${GUEST_USER}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' bash '$AGY_INSTALLER'" \
        </dev/null

    # Keep absolute-path callers working after self-updates; replace the link
    # itself, not a directory it may point to.
    ln -s "$AGY_NATIVE_BIN" "$AGY_LINK_TMP"
    mv -Tf "$AGY_LINK_TMP" /usr/local/bin/agy

    if ! su - "$GUEST_USER" -c '/usr/local/bin/agy --version' </dev/null; then
        echo '  [guest] ERROR: Antigravity CLI is not usable through /usr/local/bin/agy' >&2
        exit 1
    fi
)
