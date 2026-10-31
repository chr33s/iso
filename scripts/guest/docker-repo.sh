set -euo pipefail

# The Docker CE key file's primary keys must be exactly the pinned set
# (sorted, space-separated): every key in the file is installed for apt.
DOCKER_KEY_FPRS='9DC858229FC7DD38854AE2D88D81803C0EBFCD88'

echo '  [guest] Adding Docker CE repository...'
install -m 0755 -d /etc/apt/keyrings
key=$(mktemp)
trap 'rm -f "$key"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL -o "$key" https://download.docker.com/linux/ubuntu/gpg
# Each primary key's fingerprint is the fpr record right after its pub record.
actual=$(gpg --show-keys --with-colons "$key" \
    | awk -F: '$1 == "pub" { primary = 1; next } primary && $1 == "fpr" { print $10 } { primary = 0 }' \
    | LC_ALL=C sort | paste -sd ' ' -)
if [ "$actual" != "$DOCKER_KEY_FPRS" ]; then
    echo "  [guest] ERROR: Docker primary key fingerprints are ${actual:-missing}," \
         "expected $DOCKER_KEY_FPRS" >&2
    exit 1
fi
gpg --dearmor < "$key" > /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
