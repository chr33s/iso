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
"$init" -y --no-modify-path --default-toolchain stable </dev/null
cp /root/.cargo/bin/* /usr/local/bin/ 2>/dev/null || true
