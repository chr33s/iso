set -euo pipefail

# Mozilla's apt repository for the `desktop` profile's browser
# (docs/design/linux-desktop-virtio-gpu.md §7). Ubuntu 24.04's `firefox`
# package installs a snap, which does not run in iso guests, so Mozilla's
# `firefox` is pinned above Ubuntu's, at the priority Mozilla's instructions
# use. Nothing else is taken from that repository: every other package in
# it is pinned below zero, which apt never installs. The key file's primary
# keys must be exactly the pinned set.
MOZILLA_KEY_FPRS='35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3'

echo '  [guest] Adding the Mozilla repository...'
install -m 0755 -d /etc/apt/keyrings
key=$(mktemp)
trap 'rm -f "$key"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL -o "$key" https://packages.mozilla.org/apt/repo-signing-key.gpg
actual=$(gpg --show-keys --with-colons "$key" \
    | awk -F: '$1 == "pub" { primary = 1; next } primary && $1 == "fpr" { print $10 } { primary = 0 }' \
    | LC_ALL=C sort | paste -sd ' ' -)
if [ "$actual" != "$MOZILLA_KEY_FPRS" ]; then
    echo "  [guest] ERROR: Mozilla repository primary key fingerprints are ${actual:-missing}," \
         "expected $MOZILLA_KEY_FPRS" >&2
    exit 1
fi
install -m 0644 "$key" /etc/apt/keyrings/packages.mozilla.org.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] \
    https://packages.mozilla.org/apt mozilla main" > /etc/apt/sources.list.d/mozilla.list
cat > /etc/apt/preferences.d/mozilla <<'ISO_MOZILLA_EOF'
Package: firefox
Pin: origin packages.mozilla.org
Pin-Priority: 1000

Package: *
Pin: origin packages.mozilla.org
Pin-Priority: -1
ISO_MOZILLA_EOF
