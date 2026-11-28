# Build environment for iso's desktop kernel (scripts/build-desktop-kernel.sh):
# a native arm64 toolchain on the same pinned base image iso's guest images use.
FROM docker.io/library/ubuntu:26.04@sha256:d66b366dac61b575bee2aef07e9c26e8070096fbe84a3d4d3eb0da069b5d76db
# The toolchain comes from one dated snapshot of the Ubuntu archive, so a
# later gcc or binutils update does not change the kernel's hash
# (KernelPin.desktopAllowed). To move it, change the timestamp, rebuild and
# re-pin. Only ca-certificates, which the snapshot host's TLS needs, comes
# from the live archive first; anything it upgraded is put back to the
# snapshot's version by --allow-downgrades.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && snapshot="--snapshot 20261109T000000Z \
      -o Acquire::Snapshots::URI::Host::ports.ubuntu.com=https://snapshot.ubuntu.com/ubuntu/@SNAPSHOTID@/" \
 && apt-get update $snapshot \
 && DEBIAN_FRONTEND=noninteractive apt-get install $snapshot -y --allow-downgrades \
      --no-install-recommends \
      bc bison flex gcc libc6-dev libelf-dev libssl-dev make perl python3 xz-utils \
 && apt-get clean && rm -rf /var/lib/apt/lists/*
