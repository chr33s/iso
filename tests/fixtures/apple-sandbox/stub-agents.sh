#!/bin/bash
set -euo pipefail

# This suite tests VM lifecycle and isolation with --no-agents, not agent
# installation. Fail loudly if a test accidentally tries to run an agent.
install -d -m 0755 /home/ubuntu/.local/bin
cat > /home/ubuntu/.local/bin/claude <<'STUB'
#!/bin/sh
echo 'VM boundary fixture: agent execution is not supported' >&2
exit 125
STUB
chmod 0755 /home/ubuntu/.local/bin/claude
install -m 0755 /home/ubuntu/.local/bin/claude /usr/local/bin/codex
