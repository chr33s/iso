#!/bin/sh
# Build the Q0 spike into .build/q0: the host owner (signed with the
# virtualization entitlement), the guest fixture app bundle, and the guest helper.
set -eu
cd "$(dirname "$0")"
swift build -c release --force-resolved-versions
bin=$(swift build -c release --show-bin-path)
out=.build/q0
rm -rf "$out"
mkdir -p "$out/Q0Fixture.app/Contents/MacOS"

cp "$bin/q0-owner" "$out/q0-owner"
codesign --force --sign - --entitlements q0-owner.entitlements "$out/q0-owner"

cp "$bin/q0-fixture" "$out/Q0Fixture.app/Contents/MacOS/Q0Fixture"
cp Q0Fixture-Info.plist "$out/Q0Fixture.app/Contents/Info.plist"
codesign --force --sign - "$out/Q0Fixture.app"

cp "$bin/q0-helper" "$out/q0helper"
codesign --force --sign - "$out/q0helper"
echo "built $out"
