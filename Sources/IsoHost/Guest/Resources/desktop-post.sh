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
