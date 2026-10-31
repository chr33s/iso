set -euo pipefail

# The GitHub CLI archive keyring's primary keys must be exactly the pinned set
# (sorted, space-separated): every key in the file is installed for apt.
GH_KEY_FPRS='2C6106201985B60E6C7AC87323F3D4EA75716059 7F38BBB59D064DBCB3D84D725612B36462313325'

echo '  [guest] Adding GitHub CLI repository...'
key=$(mktemp)
trap 'rm -f "$key"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL -o "$key" \
    https://cli.github.com/packages/githubcli-archive-keyring.gpg
# Each primary key's fingerprint is the fpr record right after its pub record.
actual=$(gpg --show-keys --with-colons "$key" \
    | awk -F: '$1 == "pub" { primary = 1; next } primary && $1 == "fpr" { print $10 } { primary = 0 }' \
    | LC_ALL=C sort | paste -sd ' ' -)
if [ "$actual" != "$GH_KEY_FPRS" ]; then
    echo "  [guest] ERROR: GitHub CLI primary key fingerprints are ${actual:-missing}," \
         "expected $GH_KEY_FPRS" >&2
    exit 1
fi
install -m 0644 "$key" /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
    https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
