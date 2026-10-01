# Bridge the guest's loopback port to the inference gateway socket that the
# sandbox runtime relays in over vsock (secure-local-inference spec §22).
# Idempotent; run as root on each new gateway session. The port and socket
# path match InferenceController.guestPort and InferenceRelay.guestPath.
(
    set -euo pipefail
    socket=/var/lib/iso-inference/gateway.sock
    port=10788
    proxyd=/usr/lib/systemd/systemd-socket-proxyd
    [ -x "$proxyd" ] || proxyd=/lib/systemd/systemd-socket-proxyd
    if [ ! -x "$proxyd" ]; then
        echo "systemd-socket-proxyd is not installed in the guest" >&2
        exit 1
    fi
    units=/etc/systemd/system

    cat > "$units/iso-inference.socket.new" <<EOF
[Unit]
Description=iso inference gateway (guest loopback)

[Socket]
ListenStream=127.0.0.1:${port}

[Install]
WantedBy=sockets.target
EOF
    cat > "$units/iso-inference.service.new" <<EOF
[Unit]
Description=iso inference gateway bridge to the vsock relay
Requires=iso-inference.socket
After=iso-inference.socket

[Service]
ExecStart=${proxyd} ${socket}
EOF
    mv -f "$units/iso-inference.socket.new" "$units/iso-inference.socket"
    mv -f "$units/iso-inference.service.new" "$units/iso-inference.service"
    systemctl daemon-reload
    systemctl enable --now iso-inference.socket >/dev/null 2>&1
    systemctl is-active --quiet iso-inference.socket
)
