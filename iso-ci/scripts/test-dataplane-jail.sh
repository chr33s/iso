#!/bin/sh
# Runs the confined data-plane self-test with the built iso-ci executable:
# the child must be unable to read a controller-private probe file, write
# outside its staging directory, open outbound TCP or execute a process,
# while its staging directory stays writable (positive control).
# Usage: iso-ci/scripts/test-dataplane-jail.sh [path/to/iso-ci]
set -eu
here=$(cd "$(dirname "$0")/.." && pwd -P)
exe=${1:-}
if [ -z "$exe" ]; then
  swift build --package-path "$here" >/dev/null
  exe="$(swift build --package-path "$here" --show-bin-path)/iso-ci"
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/iso-ci-jail.XXXXXX")
work=$(cd "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT
mkdir -m 700 "$work/staging" "$work/sockets"
printf 'controller-private\n' > "$work/probe"
chmod 600 "$work/probe"
profile="$here/scripts/dataplane-seatbelt.sb"
python3 - "$exe" "$work" "$profile" <<'PY'
import json, os, socket, subprocess, sys
exe, work, profile = sys.argv[1:4]
# The profile allows exec of one literal path: pass the resolved one, as
# the supervisor does (symlinked build directories would be denied).
exe = os.path.realpath(exe)
listener = socket.socket(); listener.bind(("127.0.0.1", 0)); listener.listen(1)
port = listener.getsockname()[1]
result = subprocess.run(
    ["/usr/bin/sandbox-exec", "-f", profile, "-D", f"EXE={exe}", "-D", f"STAGING={work}/staging",
     "-D", f"SOCKETS={work}/sockets", exe, "_dataplane", "--jail-selftest", "--staging",
     f"{work}/staging", "--probe", f"{work}/probe", "--tcp-port", str(port)],
    capture_output=True, env={}, timeout=60)
line = result.stdout.decode().strip().splitlines()[-1] if result.stdout else "{}"
report = json.loads(line)
print(json.dumps(report, sort_keys=True))
if result.returncode != 0 or report.get("confined") is not True:
    sys.exit("data-plane confinement self-test FAILED")
print("data-plane confinement self-test passed")
PY
