#!/bin/sh
# Build the probe into .build/probe: the host probe (signed with the
# virtualization entitlement), the guest fixture app bundle, and the guest helper.
set -eu
cd "$(dirname "$0")"
swift build -c release --force-resolved-versions
bin=$(swift build -c release --show-bin-path)
out=.build/probe
rm -rf "$out"
mkdir -p "$out/IsoVZProbe.app/Contents/MacOS"

cp "$bin/vz-context-probe" "$out/vz-context-probe"
codesign --force --sign - --entitlements probe.entitlements "$out/vz-context-probe"

cp "$bin/iso-vz-probe-fixture" "$out/IsoVZProbe.app/Contents/MacOS/IsoVZProbe"
cp Fixture-Info.plist "$out/IsoVZProbe.app/Contents/Info.plist"
codesign --force --sign - "$out/IsoVZProbe.app"

cp "$bin/iso-vz-probe-helper" "$out/iso-vz-probe-helper"
codesign --force --sign - "$out/iso-vz-probe-helper"
git rev-parse HEAD > "$out/build-commit" 2>/dev/null || echo unknown > "$out/build-commit"
shasum -a 256 "$out/vz-context-probe" | cut -d' ' -f1 > "$out/build-hash"
echo "built $out"
