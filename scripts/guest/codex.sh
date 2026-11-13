# Derived from trailofbits/coop.
# Modified by chr33s: ported/adapted for the Swift implementation.
# SPDX-License-Identifier: Apache-2.0

# Keep the installer cleanup local when provisioning snippets are concatenated.
(
    set -euo pipefail
    : "${GUEST_USER:?GUEST_USER must be set by the orchestrator}"

    # Profiles may supply their own Codex; explicit updates replace it.
    if [ -z "${ISO_FORCE_INSTALL:-}" ] && [ -x /usr/local/bin/codex ]; then
        echo '  [guest] Codex CLI already installed, skipping.'
        exit 0
    fi

    echo '  [guest] Installing Codex CLI with the native installer...'
    # `iso agent update --codex` also runs this on macOS guests.
    if [ "$(uname -s)" = Darwin ]; then
        GUEST_HOME="/Users/${GUEST_USER}"
    else
        GUEST_HOME="/home/${GUEST_USER}"
    fi
    CODEX_NATIVE_BIN="${GUEST_HOME}/.local/bin/codex"
    CODEX_INSTALLER=$(mktemp)
    CODEX_LINK_TMP="/usr/local/bin/codex.new.$$"
    trap 'rm -f "$CODEX_INSTALLER" "$CODEX_LINK_TMP"' EXIT
    chmod 0644 "$CODEX_INSTALLER"

    # curl retries transient failures without running a partial script.
    curl -fsSL --retry 3 --retry-all-errors \
        -o "$CODEX_INSTALLER" https://chatgpt.com/codex/install.sh

    # Keep the upstream layout and guest ownership for `codex update`; iso already manages PATH.
    su - "$GUEST_USER" -c \
        "PATH='${GUEST_HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' CODEX_NON_INTERACTIVE=1 sh '$CODEX_INSTALLER'" \
        </dev/null

    # Keep existing iso wrappers and absolute-path callers working after updates.
    ln -s "$CODEX_NATIVE_BIN" "$CODEX_LINK_TMP"
    # Replace the link itself, not a directory it may point to (`-T` is GNU-only).
    if [ "$(uname -s)" = Darwin ]; then
        mv -fh "$CODEX_LINK_TMP" /usr/local/bin/codex
    else
        mv -Tf "$CODEX_LINK_TMP" /usr/local/bin/codex
    fi

    # The native installer validates its package; verify iso's link as its user.
    if ! su - "$GUEST_USER" -c '/usr/local/bin/codex --version' </dev/null; then
        echo '  [guest] ERROR: Codex is not usable through /usr/local/bin/codex' >&2
        exit 1
    fi
)
