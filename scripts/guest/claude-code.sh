# Derived from trailofbits/coop.
# Modified by chr33s: ported/adapted for the Swift implementation.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# GUEST_USER is exported by the image build (ImageBuild.swift).
: "${GUEST_USER:?GUEST_USER must be set by the orchestrator}"

# Skip if a profile already provided a claude binary (e.g. stub-claude). if/else, not `exit 0`:
# this file is concatenated with codex.sh and an exit would skip the codex installer.
# would skip the codex installer too.
if [ -x "/home/${GUEST_USER}/.local/bin/claude" ]; then
    echo '  [guest] Claude Code CLI already installed, skipping.'
else
    echo '  [guest] Installing Claude Code CLI...'

    # Download to a file first: `curl | bash` lets the installer inherit curl's pipe as stdin and
    # hang on prompts in non-interactive contexts. Run it with stdin from /dev/null.
    INSTALLER=$(mktemp)
    chmod 644 "$INSTALLER"
    trap 'rm -f "$INSTALLER"' EXIT

    # Retry with backoff (DNS/CDN hiccups during cloud-init); each attempt is time-bounded. Status is
    # read in the failed branch: after `fi`, $? is the `if`'s own status, not curl's.
    echo '  [guest] Downloading Claude Code installer...'
    MAX_RETRIES=4
    RETRY_DELAY=5
    for attempt in $(seq 1 "$MAX_RETRIES"); do
        if curl -fsSL --connect-timeout 15 --max-time 120 \
            -o "$INSTALLER" https://claude.ai/install.sh 2>/tmp/claude-curl-err; then
            break
        else
            CURL_EXIT=$?
        fi
        CURL_ERR=$(cat /tmp/claude-curl-err 2>/dev/null || true)
        if [ "$attempt" -eq "$MAX_RETRIES" ]; then
            echo "  [guest] ERROR: Failed to download Claude Code installer" \
                 "after $MAX_RETRIES attempts." >&2
            echo "  [guest] curl exit code: $CURL_EXIT" >&2
            echo "  [guest] curl error: ${CURL_ERR:-none}" >&2
            exit 1
        fi
        echo "  [guest] Download failed (attempt $attempt/$MAX_RETRIES," \
             "curl exit $CURL_EXIT), retrying in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
        RETRY_DELAY=$((RETRY_DELAY * 2))
    done

    echo '  [guest] Download complete; running Claude Code installer...'
    su - "${GUEST_USER}" -c "bash '$INSTALLER'" </dev/null
    echo '  [guest] Claude Code installer finished.'
fi
