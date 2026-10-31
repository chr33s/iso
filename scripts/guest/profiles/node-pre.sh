set -euo pipefail

# NodeSource's apt repository, configured directly instead of running its
# setup script as root. The key file's primary keys must be exactly the pinned
# set (sorted, space-separated): every key in the file is installed for apt.
NODESOURCE_KEY_FPRS='6F71F525282841EEDAF851B42F59B5F99B1BE0B4'

echo '  [guest] Adding NodeSource 22.x repository...'
install -m 0755 -d /etc/apt/keyrings
key=$(mktemp)
trap 'rm -f "$key"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL -o "$key" \
    https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key
# Each primary key's fingerprint is the fpr record right after its pub record.
actual=$(gpg --show-keys --with-colons "$key" \
    | awk -F: '$1 == "pub" { primary = 1; next } primary && $1 == "fpr" { print $10 } { primary = 0 }' \
    | LC_ALL=C sort | paste -sd ' ' -)
if [ "$actual" != "$NODESOURCE_KEY_FPRS" ]; then
    echo "  [guest] ERROR: NodeSource primary key fingerprints are ${actual:-missing}," \
         "expected $NODESOURCE_KEY_FPRS" >&2
    exit 1
fi
gpg --dearmor < "$key" > /etc/apt/keyrings/nodesource.gpg
chmod a+r /etc/apt/keyrings/nodesource.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/nodesource.gpg] \
    https://deb.nodesource.com/node_22.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
printf 'Package: nodejs\nPin: origin deb.nodesource.com\nPin-Priority: 600\n' \
    > /etc/apt/preferences.d/nodesource
