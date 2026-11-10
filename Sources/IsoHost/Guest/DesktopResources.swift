import Foundation

/// The `desktop` image profile's guest scripts
/// (docs/design/linux-desktop-virtio-gpu.md §7). Each is byte-identical to
/// its checked-in copy in `Guest/Resources/`, which a test compares.
enum DesktopResources {
  /// `desktop-pre.sh`: Mozilla's apt repository, for the browser.
  static let preInstall = #"""
    set -euo pipefail

    # Mozilla's apt repository for the `desktop` profile's browser
    # (docs/design/linux-desktop-virtio-gpu.md §7). Ubuntu 24.04's `firefox`
    # package installs a snap, which does not run in iso guests, so the
    # repository is pinned above Ubuntu's archive for Mozilla's packages. The
    # key file's primary keys must be exactly the pinned set.
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
    Package: *
    Pin: origin packages.mozilla.org
    Pin-Priority: 1000
    ISO_MOZILLA_EOF

    """#

  /// `desktop-post.sh`: the display server, window manager and their
  /// boot-time configuration.
  static let postInstall = #"""
    set -euo pipefail

    # The `desktop` profile (docs/design/linux-desktop-virtio-gpu.md §7): Xorg
    # on the virtio-gpu scanout, openbox, and the iso-cu MCP server. Nothing in
    # the guest captures, encodes or injects: pixels and input travel through
    # the VM's own display and USB devices.
    echo '  [guest] Configuring the desktop display...'
    install -d -m 0755 /usr/local/libexec/iso-display
    cat > /usr/local/libexec/iso-display/xorg-config <<'ISO_DISPLAY_EOF'
    #!/bin/sh
    # Writes this boot's display-server configuration: the virtio-gpu scanout,
    # and the hypervisor's USB keyboard and pointer found by name. udev is
    # masked in iso images, so nothing hot-plugs them and libinput, which needs
    # udev's properties, cannot be used; the evdev driver reads the devices
    # directly.
    set -eu
    out=/run/iso-display/xorg.conf
    mkdir -p /run/iso-display
    event_for() {
      awk -v want="$1" '
        /^N: Name=/ { name = substr($0, 9); gsub(/"/, "", name) }
        /^H: Handlers=/ {
          if (name == want) for (i = 2; i <= NF; i++) if ($i ~ /^event[0-9]+$/) { print $i; exit }
        }
      ' /proc/bus/input/devices
    }
    # The USB devices enumerate shortly after boot: wait up to 15 s for them.
    i=0
    while :; do
      kbd=$(event_for "Apple Inc. Virtual USB Keyboard")
      ptr=$(event_for "Apple Inc. Virtual USB Digitizer")
      if [ -n "$kbd" ] && [ -n "$ptr" ] && [ -e /dev/dri/card0 ]; then break; fi
      i=$((i + 1))
      [ "$i" -lt 150 ] || break
      sleep 0.1
    done
    if [ -z "$kbd" ] || [ -z "$ptr" ]; then
      echo "iso-display: the VM's USB keyboard or pointer is missing" >&2
      exit 1
    fi
    cat > "$out.tmp" <<EOF
    Section "ServerFlags"
      Option "AutoAddDevices" "false"
      Option "AutoEnableDevices" "false"
      Option "DontVTSwitch" "true"
      Option "BlankTime" "0"
      Option "StandbyTime" "0"
      Option "SuspendTime" "0"
      Option "OffTime" "0"
    EndSection
    Section "Device"
      Identifier "virtio"
      Driver "modesetting"
      Option "kmsdev" "/dev/dri/card0"
    EndSection
    Section "Screen"
      Identifier "screen"
      Device "virtio"
      DefaultDepth 24
      SubSection "Display"
        Modes "1920x1200"
      EndSubSection
    EndSection
    Section "InputDevice"
      Identifier "keyboard"
      Driver "evdev"
      Option "Device" "/dev/input/$kbd"
      Option "XkbLayout" "us"
    EndSection
    Section "InputDevice"
      Identifier "pointer"
      Driver "evdev"
      Option "Device" "/dev/input/$ptr"
    EndSection
    Section "ServerLayout"
      Identifier "iso"
      Screen "screen"
      InputDevice "keyboard" "CoreKeyboard"
      InputDevice "pointer" "CorePointer"
    EndSection
    EOF
    mv "$out.tmp" "$out"
    ISO_DISPLAY_EOF
    chmod 0755 /usr/local/libexec/iso-display/xorg-config

    cat > /etc/systemd/system/iso-display.service <<'ISO_DISPLAY_EOF'
    [Unit]
    Description=iso display server on the virtio-gpu scanout
    ConditionPathExists=/dev/dri/card0
    # Each start of the display server, a restart included, starts the window
    # manager after it.
    Wants=iso-display-wm.service

    [Service]
    ExecStartPre=/usr/local/libexec/iso-display/xorg-config
    ExecStart=/usr/lib/xorg/Xorg :0 -config /run/iso-display/xorg.conf -nolisten tcp -noreset -novtswitch -logfile /var/log/iso-display.log
    Restart=on-failure
    RestartSec=2

    [Install]
    WantedBy=multi-user.target
    ISO_DISPLAY_EOF

    cat > /etc/systemd/system/iso-display-wm.service <<'ISO_DISPLAY_EOF'
    [Unit]
    Description=iso window manager on the display
    BindsTo=iso-display.service
    After=iso-display.service

    [Service]
    User=1000
    Environment=DISPLAY=:0
    ExecStartPre=/bin/sh -c 'for i in $(seq 100); do xdpyinfo >/dev/null 2>&1 && exit 0; sleep 0.1; done; exit 1'
    ExecStart=/usr/bin/openbox
    Restart=on-failure
    RestartSec=2

    [Install]
    WantedBy=multi-user.target
    ISO_DISPLAY_EOF

    echo 'export DISPLAY=:0' > /etc/profile.d/iso-display.sh
    systemctl enable iso-display.service iso-display-wm.service

    """#
}
