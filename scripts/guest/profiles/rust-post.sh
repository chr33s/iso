set -euo pipefail

# rustup-init at a pinned version, checked against its pinned SHA-256 before
# it runs; never the rustup.sh bootstrap script piped to a shell.
RUSTUP_VERSION=1.29.2
case "$(uname -m)" in
    aarch64|arm64)
        RUSTUP_TARGET=aarch64-unknown-linux-gnu
        RUSTUP_SHA256=a9c168dbea81a84671c6b7a5c1795cb0eb699020110d107ddfca427bd797e697 ;;
    x86_64)
        RUSTUP_TARGET=x86_64-unknown-linux-gnu
        RUSTUP_SHA256=5be191e8c70a5007074254cb74d78dbfdd25cd5a61c27de7b8e5410122ec24f4 ;;
    *)
        echo "  [guest] ERROR: no pinned rustup-init for $(uname -m)" >&2
        exit 1 ;;
esac

echo "  [guest] Installing Rust via rustup-init ${RUSTUP_VERSION}..."
init=$(mktemp)
trap 'rm -f "$init"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL -o "$init" \
    "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${RUSTUP_TARGET}/rustup-init"
echo "${RUSTUP_SHA256}  ${init}" | sha256sum -c --quiet -
chmod 0755 "$init"
# A shared install, not root's ~/.rustup: the guest user runs the toolchain.
# The rustup proxies find it through RUSTUP_HOME, which /etc/environment sets
# for every session (pam_env). Writable by all, as in the official Rust image,
# so the guest user can add toolchains and cargo can cache crates.
RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo \
    "$init" -y --no-modify-path --default-toolchain stable </dev/null
chmod -R a+w /usr/local/rustup /usr/local/cargo
ln -sf /usr/local/cargo/bin/* /usr/local/bin/
grep -q '^RUSTUP_HOME=' /etc/environment 2>/dev/null \
    || echo 'RUSTUP_HOME="/usr/local/rustup"' >> /etc/environment
grep -q '^CARGO_HOME=' /etc/environment 2>/dev/null \
    || echo 'CARGO_HOME="/usr/local/cargo"' >> /etc/environment
