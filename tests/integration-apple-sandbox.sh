#!/usr/bin/env bash
set -uo pipefail

# Real-hardware checks for iso-sandbox (iso-sandbox), the runtime
# behind the `apple-container` build. Unit tests cannot boot VMs; this boots
# real ones and checks what the backend's isolation contract relies on
# (docs/trust-model.md): peer isolation between sandboxes, no host mounts,
# agent sockets, or canary leakage, pinned SSH over the native channel, and
# the lifecycle (persistence, resources, disk growth, commit/restore, crash
# recovery and interrupted mutations, concurrency).
#
# Usage: tests/integration-apple-sandbox.sh [--only PHASE[,PHASE...]] [--keep]
#   Phases: setup disks machine isolation exposure identity persistence
#           resources growth snapshots recovery concurrency iso inference
#   CYCLES=5 stop/start cycles; CONCURRENCY="1 4 8" sandboxes per round;
#   KILL_FRACTIONS="50 75 90 95 100 105 110": an interrupted mutation is
#   killed at these percentages of the time an uninterrupted one took;
#   ISO_KILL_FRACTIONS="25 50 75" the same for iso's.
#
# Needs Apple Silicon, macOS 27+, Xcode 27, jq, and stock Apple `container`
# with its service running (builds the test image, supplies the kernel). It
# touches nothing but its own state root and image tag, both removed on exit.
# The iso phase also builds `iso` (into the work
# directory) and drives it end to end against a data directory there; the
# images `iso setup` builds in the stock `container` store are deleted too.

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "SKIP: iso-sandbox needs an Apple Silicon Mac"
    exit 0
fi
CONTAINER=""
for candidate in /usr/local/bin/container /opt/homebrew/bin/container; do
    [[ -x "$candidate" ]] && { CONTAINER="$candidate"; break; }
done
[[ -n "$CONTAINER" ]] || { echo "SKIP: no Apple container CLI installed"; exit 0; }
for tool in swift jq ssh ssh-keygen nc openssl python3; do
    command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
done

ONLY=""
KEEP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --only) ONLY=",$2,"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
want() { [[ -z "$ONLY" || "$ONLY" == *",$1,"* ]]; }

cd "$(dirname "$0")/.." || exit 1
FIXTURES="$PWD/tests/fixtures/apple-sandbox"
RUN="t$(openssl rand -hex 4)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/iso-sandbox-test.XXXXXX")"
ROOT="$WORK/root"
IMAGE="local/iso-sandbox-test:$RUN"
MAINTENANCE="local/iso-sandbox-test-maintenance:$RUN"
SANDBOX="$WORK/bin/iso-sandbox"
CYCLES="${CYCLES:-5}"
CONCURRENCY="${CONCURRENCY:-1 4 8}"
KILL_FRACTIONS="${KILL_FRACTIONS:-50 75 90 95 100 105 110}"
ISO_KILL_FRACTIONS="${ISO_KILL_FRACTIONS:-25 50 75}"
# A secret that exists only in this script's environment; it must never reach
# the runtime, its logs, the image, or a guest.
CANARY="iso-test-canary-$(openssl rand -hex 16)"
export CANARY

pass_count=0
fail_count=0
skip_count=0

pass() {
    pass_count=$((pass_count + 1))
    echo "  PASS  $1"
}

fail() {
    fail_count=$((fail_count + 1))
    echo "  FAIL  $1"
    if [[ -n "${2:-}" ]]; then
        echo "        $2"
    fi
}

skip() {
    skip_count=$((skip_count + 1))
    echo "  SKIP  $1${2:+ ($2)}"
}

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

# timed_ms CMD...: run CMD and print how long it took, in milliseconds.
timed_ms() {
    local t0
    t0="$(now_ms)"
    "$@" >/dev/null 2>&1
    echo $(($(now_ms) - t0))
}

# delay_s MS PERCENT: PERCENT of MS, as seconds for sleep.
delay_s() {
    local ms=$(($1 * $2 / 100))
    printf '%d.%03d' $((ms / 1000)) $((ms % 1000))
}

check() {
    local label="$1"
    shift
    if "$@"; then pass "$label"; else fail "$label"; fi
}

# refuses CMD...: CMD must fail.
refuses() { ! "$@" >/dev/null 2>&1; }

summary() {
    echo ""
    echo "────────────────────────────────────────"
    echo "  $pass_count passed, $fail_count failed, $skip_count skipped"
    echo "────────────────────────────────────────"
    if [[ $fail_count -gt 0 ]]; then
        exit 1
    fi
}

# ── Runtime helpers ───────────────────────────────────────────

sbx() { "$SANDBOX" "$1" --root "$ROOT" "${@:2}"; }
# Two-word subcommands take --root after both words.
sbx2() { "$SANDBOX" "$1" "$2" --root "$ROOT" "${@:3}"; }
name() { echo "iso-test-$1-$RUN"; }
create() { sbx create "$1" --image "$IMAGE" --cpus "${2:-2}" --memory-mib "${3:-2048}" --disk-gib "${4:-8}" --owner "$RUN" >/dev/null; }
state() { sbx inspect "$1" 2>/dev/null | jq -r .status 2>/dev/null || echo missing; }
guest() { local n="$1"; shift; sbx exec "$n" -- "$@"; }
guest_in() { local n="$1"; shift; sbx exec -i "$n" -- "$@"; }
ip4() { sbx inspect "$1" | jq -r '.live.ipv4 // empty'; }
ip6() {
    local a i
    for ((i = 0; i < 40; i++)); do
        a="$(guest "$1" ip -6 -o addr show eth0 scope global | awk '{print $4}' | cut -d/ -f1 | head -1)"
        [[ -n "$a" ]] && { echo "$a"; return 0; }
        sleep 0.5
    done
    return 1
}

# systemd running (or degraded) with sshd and Docker active.
ready() {
    local n="$1" i st
    for ((i = 0; i < 600; i++)); do
        st="$(guest "$n" systemctl is-system-running 2>/dev/null || true)"
        if [[ "$st" == running || "$st" == degraded ]] && guest "$n" systemctl is-active --quiet ssh docker 2>/dev/null; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

boot() { sbx start "$1" >/dev/null && ready "$1"; }
verify() { guest "$1" /usr/local/sbin/iso-test-verify; }

# ── Peer isolation probes ─────────────────────────────────────

# peer-probe.sh prints at least this many results; fewer means it failed.
MIN_PROBES=17

# listeners TARGET: TCP/UDP echo on 7777/7778 as systemd units.
listeners() {
    guest "$1" sh -c '
        sysctl -qw net.ipv4.icmp_echo_ignore_broadcasts=0
        systemctl is-active --quiet iso-test-tcp || systemd-run --quiet --unit=iso-test-tcp socat TCP6-LISTEN:7777,ipv6only=0,fork,reuseaddr SYSTEM:"echo pong"
        systemctl is-active --quiet iso-test-udp || systemd-run --quiet --unit=iso-test-udp socat UDP6-RECVFROM:7778,ipv6only=0,fork SYSTEM:"echo upong"' >/dev/null
    sleep 0.5
}

# probe_pair ATTACKER TARGET: prints "REACHED|HOST_MISSES|PROBES". The target
# must already run listeners. Probes rewrite the attacker's routes and
# addresses, so one attacker runs one probe_pair at a time.
probe_pair() {
    local from="$1" to="$2" t4 t6 mac ll results reached host
    t4="$(ip4 "$to")"
    t6="$(ip6 "$to")"
    mac="$(guest "$to" cat /sys/class/net/eth0/address)"
    ll="$(guest "$to" ip -6 -o addr show eth0 scope link | awk '{print $4}' | cut -d/ -f1 | head -1)"
    guest_in "$from" sh -c 'cat > /tmp/probe.sh && chmod +x /tmp/probe.sh' <"$FIXTURES/peer-probe.sh"
    results="$(guest "$from" /tmp/probe.sh "$t4" "$t6" "$mac" "$ll")"
    reached="$(jq -rs '[.[] | select(.reached) | .probe] | join(",")' <<<"$results")"
    # TCP and IPv6 replies reach host sockets; IPv4 UDP/ICMP replies from
    # vmnet guests do not on macOS, so those are not host controls.
    host="$("$FIXTURES/host-probe.sh" "$t4" "$t6" | jq -r '[to_entries[] | select(.value == false and (.key | IN("ipv4-icmp","ipv4-udp") | not)) | .key] | join(",")')"
    echo "$reached|$host|$(grep -c '"probe"' <<<"$results")"
}

# isolated RESULT: a probe_pair result with every vector blocked, every host
# control answered, and the full probe set run.
isolated() {
    local reached host n
    IFS='|' read -r reached host n <<<"$1"
    [[ -z "$reached" && -z "$host" && "${n:-0}" -ge $MIN_PROBES ]]
}

cleanup() {
    local rc=$?
    if (( KEEP == 0 )); then
        if [[ -x "$SANDBOX" && -d "$ROOT" ]]; then
            for n in $(sbx list 2>/dev/null | jq -r '.[].id' 2>/dev/null); do
                sbx stop "$n" >/dev/null 2>&1
                sbx delete "$n" --owner "$RUN" >/dev/null 2>&1
            done
        fi
        "$CONTAINER" image delete "$IMAGE" "$MAINTENANCE" >/dev/null 2>&1
        iso_cleanup
        rm -rf "$WORK"
    else
        echo "Kept $WORK"
    fi
    exit "$rc"
}
trap cleanup EXIT

# ── iso end to end ──────────────────────────────────────────

ISO="$WORK/swift-build/debug/iso"
CDATA="$WORK/iso-data"
CSTATE="$CDATA/backends/apple-container-v1"
CROOT="$CSTATE/runtime"
CCFG="$WORK/iso.jsonc"
# Same config with a short boot deadline, for a restart whose guest never
# starts sshd.
CCFG_FAIL="$WORK/iso-fail.jsonc"

iso() { "$ISO" --config "$CCFG" "$@" </dev/null; }
csbx() { "$SANDBOX" "$1" --root "$CROOT" "${@:2}"; }
machine_id() { jq -r .machine_id "$CSTATE/instances/$1/apple-machine.json"; }
record() { csbx inspect "$(machine_id "$1")" | jq -r ".record.$2"; }
cstate() { iso status "$1" --json | jq -r .state; }

iso_cleanup() {
    [[ -d "$CROOT" && -x "$SANDBOX" ]] || return 0
    local id owner short
    for id in $(csbx list 2>/dev/null | jq -r '.[].id' 2>/dev/null); do
        owner="$(csbx inspect "$id" 2>/dev/null | jq -r .record.owner)"
        csbx stop "$id" >/dev/null 2>&1
        csbx delete "$id" --owner "$owner" >/dev/null 2>&1
    done
    short="$(jq -r '.owner_id // empty' "$CSTATE/owner.json" 2>/dev/null | cut -c1-8)"
    [[ -n "$short" ]] || return 0
    local images
    images="$("$CONTAINER" image list --quiet 2>/dev/null | grep "^local/iso-$short")"
    # shellcheck disable=SC2086 # one image reference per word.
    [[ -z "$images" ]] || "$CONTAINER" image delete $images >/dev/null 2>&1
}

# ── Pinned SSH (never the host agent or ~/.ssh) ─────────────

KEY="$WORK/id"
KNOWN="$WORK/known_hosts"

enroll() {
    guest_in "$1" sh -c 'umask 077; mkdir -p /root/.ssh; cat > /root/.ssh/authorized_keys' <"$KEY.pub"
    grep -v "^$1 " "$KNOWN" >"$KNOWN.tmp" 2>/dev/null || true
    echo "$1 $(guest "$1" cut -d' ' -f1-2 /etc/ssh/ssh_host_ed25519_key.pub)" >>"$KNOWN.tmp"
    mv "$KNOWN.tmp" "$KNOWN"
}

pinned() {
    local n="$1"
    shift
    ssh -F /dev/null -i "$KEY" -o IdentitiesOnly=yes -o IdentityAgent=none \
        -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN" -o GlobalKnownHostsFile=/dev/null \
        -o HostKeyAlias="$n" -o HostKeyAlgorithms=ssh-ed25519 -o BatchMode=yes -o ConnectTimeout=5 \
        -o ForwardAgent=no -o LogLevel=ERROR "root@$(ip4 "$n")" "$@"
}

A="$(name a)"
B="$(name b)"

# ── Phases ────────────────────────────────────────────────────

echo "=== Phase: setup ==="
mkdir -p "$WORK/bin"
if ./scripts/build-iso-sandbox.sh "$WORK" >"$WORK/build.log" 2>&1; then
    pass "iso-sandbox builds and signs"
else
    fail "iso-sandbox builds and signs" "see $WORK/build.log"
    summary
fi
check "version reports protocol 4 on containerization 0.45.0" \
    test "$("$SANDBOX" version | jq -r '"\(.protocol) \(.containerization)"')" = "4 0.45.0"
if "$CONTAINER" build --platform linux/arm64 -t "$IMAGE" "$FIXTURES/image" >"$WORK/image.log" 2>&1 &&
    "$CONTAINER" image save --platform linux/arm64 -o "$WORK/image.tar" "$IMAGE" >/dev/null 2>&1; then
    pass "test image builds"
else
    fail "test image builds" "see $WORK/image.log"
    summary
fi
kernel="$(readlink -f "$HOME/Library/Application Support/com.apple.container/kernels/default.kernel-arm64")"
check "init accepts the pinned kernel" sbx init --kernel "$kernel"
check "init refuses an unpinned kernel" refuses "$SANDBOX" init --root "$WORK/other" --kernel "$FIXTURES/image/Dockerfile"
imported="$("$SANDBOX" image import --root "$ROOT" --oci-tar "$WORK/image.tar")"
# shellcheck disable=SC2016 # jq program text.
check "image imports into the private store" jq -e --arg r "$IMAGE" 'any(.reference == $r)' <<<"$imported"
rm -f "$WORK/image.tar"
# A maintenance image equivalent to the one iso builds
# (BuildContext.maintenanceDockerfile in Sources/IsoHost/ImageBuild.swift):
# Ubuntu with e2fsprogs.
mkdir -p "$WORK/maintenance"
printf '%s\n' 'FROM docker.io/library/ubuntu:24.04@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3' \
    'RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends e2fsprogs && rm -rf /var/lib/apt/lists/*' \
    >"$WORK/maintenance/Dockerfile"
if "$CONTAINER" build --platform linux/arm64 -t "$MAINTENANCE" "$WORK/maintenance" >"$WORK/maintenance.log" 2>&1 &&
    "$CONTAINER" image save --platform linux/arm64 -o "$WORK/maintenance.tar" "$MAINTENANCE" >/dev/null 2>&1 &&
    sbx2 image import --oci-tar "$WORK/maintenance.tar" >/dev/null; then
    pass "maintenance image builds and imports"
else
    fail "maintenance image builds and imports" "see $WORK/maintenance.log"
fi
check "maintenance installs outside the image store" sbx2 maintenance install --image "$MAINTENANCE" --version 1
sbx2 image delete "$MAINTENANCE" >/dev/null
# shellcheck disable=SC2016 # jq program text.
check "maintenance survives deleting its store image" jq -e --arg r "$MAINTENANCE" '.version == "1" and .reference == $r' <<<"$(sbx2 maintenance inspect)"
rm -f "$WORK/maintenance.tar"

if want disks; then
    echo ""
    echo "=== Phase: disks ==="
    for gib in 8 32 64; do
        n="$(name "d$gib")"
        create "$n" 2 2048 "$gib"
        if boot "$n"; then
            size="$(guest "$n" df -B1 --output=size / | tail -1 | xargs)"
            # ext4 metadata takes a little under 2 %; allow 5 %.
            check "${gib} GiB disk is ${gib} GiB in the guest" test "$size" -ge $((gib * 1024 * 1024 * 1024 * 95 / 100))
        else
            fail "${gib} GiB sandbox boots"
        fi
        sbx stop "$n"
        sbx delete "$n" --owner "$RUN"
    done
    t0="$(date +%s)"
    create "$(name cached)"
    check "a second create from the same image is a clone (<5 s)" test $(($(date +%s) - t0)) -lt 5
    sbx delete "$(name cached)" --owner "$RUN"
fi

create "$A" 4 8192 16
create "$B" 4 8192 16
check "created sandboxes are stopped and owned" test "$(sbx inspect "$A" | jq -r '"\(.status) \(.record.owner)"')" = "stopped $RUN"
boot "$A" || fail "sandbox A boots"
boot "$B" || fail "sandbox B boots"

if want machine; then
    echo ""
    echo "=== Phase: machine ==="
    v="$(verify "$A")"
    check "PID 1 is systemd" test "$(jq -r .pid1 <<<"$v")" = systemd
    check "systemd is running with no failed units" test "$(jq -r '"\(.system_state) \(.failed_units|length)"' <<<"$v")" = "running 0"
    check "sshd and Docker stay active after the exec" test "$(guest "$A" systemctl is-active ssh docker | tr '\n' ' ')" = "active active "
    check "docker runs a container" guest "$A" docker run --rm alpine:3.20 /bin/true
    check "docker builds an image" guest "$A" sh -c 'mkdir -p /tmp/b && printf "FROM alpine:3.20\nRUN echo built > /built\n" > /tmp/b/Dockerfile && docker build -q -t t /tmp/b >/dev/null'
    eff="$(sbx inspect "$A" | jq .effective)"
    check "effective config: kernel pseudo-filesystems only" \
        jq -e '[.mounts[] | select(.type | IN("proc","sysfs","devtmpfs","mqueue","tmpfs","cgroup2","devpts") | not)] | length == 0' <<<"$eff"
    check "effective config: no relays, ports, or agent forwarding" \
        jq -e '.socketRelays == 0 and .publishedPorts == 0 and .sshAgentForwarding == false' <<<"$eff"
    check "effective config: one interface on its own vmnet subnet" \
        jq -e '(.interfaces | length) == 1 and (.interfaces[0].network | startswith("vmnet-shared:10.231."))' <<<"$eff"
    # shellcheck disable=SC2016 # jq program text.
    check "effective config: boots its own disk under the root" \
        jq -e --arg p "/sandboxes/$A/rootfs.ext4" '.rootfs.type == "ext4" and (.rootfs.source | endswith($p))' <<<"$eff"
    check "effective config: requested CPUs and memory" jq -e '.cpus == 4 and .memoryBytes == 8589934592' <<<"$eff"
fi

if want isolation; then
    echo ""
    echo "=== Phase: isolation ==="
    # probe ATTACKER TARGET LABEL: every vector blocked, host control reaches the target.
    probe() {
        local label="$3" result reached host n
        listeners "$2"
        result="$(probe_pair "$1" "$2")"
        IFS='|' read -r reached host n <<<"$result"
        if [[ -n "$reached" ]]; then
            fail "$label: guest blocked on every vector" "reached via $reached"
        elif [[ -n "$host" ]]; then
            fail "$label: host positive control reaches the target" "no reply over $host"
        elif [[ "${n:-0}" -lt $MIN_PROBES ]]; then
            fail "$label: the probe ran" "only ${n:-0} of at least $MIN_PROBES results"
        else
            pass "$label: TCP/UDP/ICMP over IPv4/IPv6, forged routes, static neighbours, spoofed source, broadcast/multicast all blocked"
        fi
    }
    probe "$A" "$B" "A -> B"
    probe "$B" "$A" "B -> A"
    sbx stop "$A"; sbx stop "$B"
    boot "$A"; boot "$B"
    probe "$A" "$B" "A -> B after restarts"
fi

if want exposure; then
    echo ""
    echo "=== Phase: exposure ==="
    mi="$(guest "$A" cat /proc/self/mountinfo)"
    check "no virtiofs, 9p, FUSE, NFS, or SMB mounts" refuses grep -Eq ' - (virtiofs|9p|fuse|fuse\.[^ ]+|nfs4?|cifs|smb3?|smbfs) ' <<<"$mi"
    check "no host path in the mount table" refuses grep -q '/Users/' <<<"$mi"
    token="iso-test-file-$(openssl rand -hex 12)"
    printf '%s\n' "$token" >"$HOME/.iso-test-canary-$RUN"
    check "a host home file is not visible in the guest" \
        test -z "$(guest "$A" sh -c "grep -rslF '$token' / --exclude-dir=proc --exclude-dir=sys --exclude-dir=dev 2>/dev/null | head -1")"
    rm -f "$HOME/.iso-test-canary-$RUN"
    genv="$(guest "$A" sh -c 'tr "\0" "\n" < /proc/1/environ; env')"
    check "no SSH_AUTH_SOCK in the guest" refuses grep -q SSH_AUTH_SOCK <<<"$genv"
    socks="$(guest "$A" sh -c 'find / -xdev -type s 2>/dev/null')"
    check "no agent-like socket in the guest" refuses grep -Eiq 'agent|ssh-auth|host-services' <<<"$socks"
    # shellcheck disable=SC2016 # Expand in the guest.
    check "no host vsock listener reachable" \
        test -z "$(guest "$A" sh -c 'for p in $(seq 1 1024) 2375 5000 8080 268435456 268435457; do timeout 1 socat -u /dev/null VSOCK-CONNECT:2:$p 2>/dev/null && echo $p; done; true')"
    leaked=""
    # shellcheck disable=SC2009 # pgrep cannot match the environment `ps -E` shows.
    ps -axwwE -o command= | grep -E 'iso-sandbox (run|start)' | grep -v grep | grep -qF "$CANARY" && leaked+=" runtime-env"
    grep -qF "$CANARY" "$ROOT/sandboxes/$A/owner.log" "$ROOT/sandboxes/$A/boot.log" 2>/dev/null && leaked+=" logs"
    sbx inspect "$A" | grep -qF "$CANARY" && leaked+=" inspect"
    [[ -n "$(guest "$A" sh -c "grep -rlsF '$CANARY' / --exclude-dir=proc --exclude-dir=sys --exclude-dir=dev 2>/dev/null | head -1")" ]] && leaked+=" guest"
    check "a secret in the caller's environment reaches no runtime process, log, or guest" test -z "$leaked"
    skip "host services on the NAT gateway" "reachable by design; see docs/trust-model.md"
fi

if want identity; then
    echo ""
    echo "=== Phase: identity ==="
    ssh-keygen -q -t ed25519 -N '' -C "iso-test-$RUN" -f "$KEY"
    : >"$KNOWN"
    enroll "$A"
    check "strict SSH against the key read over the native channel" test "$(pinned "$A" echo ok)" = ok
    # shellcheck disable=SC2016 # Expand in the guest.
    check "no agent in the SSH session" test "$(pinned "$A" 'echo ${SSH_AUTH_SOCK:-none}')" = none
    fwd="$(
        eval "$(ssh-agent -s)" >/dev/null
        ssh -F /dev/null -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN" \
            -o GlobalKnownHostsFile=/dev/null -o HostKeyAlias="$A" -o BatchMode=yes -o ForwardAgent=yes -o LogLevel=ERROR \
            "root@$(ip4 "$A")" 'echo ${SSH_AUTH_SOCK:-none}'
        ssh-agent -k >/dev/null
    )"
    check "sshd refuses to forward even a throwaway agent" test "$fwd" = none
    key1="$(guest "$A" cut -d' ' -f1-2 /etc/ssh/ssh_host_ed25519_key.pub)"
    sbx stop "$A"
    boot "$A"
    check "host key is stable across restart" test "$(guest "$A" cut -d' ' -f1-2 /etc/ssh/ssh_host_ed25519_key.pub)" = "$key1"
    check "strict SSH works after restart" test "$(pinned "$A" echo ok)" = ok
    guest "$A" sh -c 'rm -f /etc/ssh/ssh_host_* && ssh-keygen -A >/dev/null && systemctl restart ssh'
    check "a replaced host key is rejected" refuses pinned "$A" true
    enroll "$A"
fi

if want persistence; then
    echo ""
    echo "=== Phase: persistence ==="
    m="$(openssl rand -hex 8)"
    guest "$A" sh -c "echo $m > /var/lib/iso-test/marker && docker volume create isovol >/dev/null && docker run --rm -v isovol:/v alpine:3.20 sh -c 'echo $m > /v/m'"
    before="$(verify "$A" | jq -c '{machine_id, ssh_host_key}')"
    lost=""
    ips=()
    for ((c = 1; c <= CYCLES; c++)); do
        u="$(openssl rand -hex 4)"
        # An unsynced write immediately before a normal stop must survive it.
        guest "$A" sh -c "echo $u > /var/lib/iso-test/unsynced"
        sbx stop "$A"
        boot "$A" || { lost+=" boot@$c"; break; }
        [[ "$(guest "$A" cat /var/lib/iso-test/marker)" == "$m" ]] || lost+=" file@$c"
        [[ "$(guest "$A" cat /var/lib/iso-test/unsynced)" == "$u" ]] || lost+=" unsynced@$c"
        [[ "$(guest "$A" docker run --rm -v isovol:/v alpine:3.20 cat /v/m)" == "$m" ]] || lost+=" docker@$c"
        [[ "$(verify "$A" | jq -c '{machine_id, ssh_host_key}')" == "$before" ]] || lost+=" identity@$c"
        ips+=("$(ip4 "$A")")
    done
    if [[ -z "$lost" ]]; then
        pass "$CYCLES stop/start cycles keep files, an unsynced pre-stop write, Docker state, machine-id, and host key"
    else
        fail "$CYCLES stop/start cycles keep files, an unsynced pre-stop write, Docker state, machine-id, and host key" "lost:$lost"
    fi
    check "the address is stable across restarts" test "$(printf '%s\n' "${ips[@]}" | sort -u | wc -l | tr -d ' ')" = 1
    n="$(name fresh)"
    create "$n"
    boot "$n"
    check "a new sandbox from the same image gets its own identity" \
        test "$(verify "$n" | jq -c '{machine_id, ssh_host_key}')" != "$before"
    sbx stop "$n"
    sbx delete "$n" --owner "$RUN"
fi

if want resources; then
    echo ""
    echo "=== Phase: resources ==="
    mid="$(guest "$A" cat /etc/machine-id)"
    sbx stop "$A"
    sbx set "$A" --cpus 2 --memory-mib 4096 >/dev/null
    boot "$A"
    v="$(verify "$A")"
    # The runtime adds one vCPU of its own.
    check "CPU change applies at the next start" test "$(jq -r .nproc <<<"$v")" = 3
    check "memory change applies at the next start" test "$(jq -r .mem_kb <<<"$v")" -lt $((4200 * 1024))
    check "the disk keeps its identity" test "$(jq -r .machine_id <<<"$v")" = "$mid"
    check "set refuses a running sandbox" refuses sbx set "$A" --cpus 1
    sbx stop "$A"
    sbx set "$A" --cpus 4 --memory-mib 8192 >/dev/null
    boot "$A"
fi

if want growth; then
    echo ""
    echo "=== Phase: growth ==="
    g="$(name grow)"
    create "$g" 2 2048 8
    boot "$g"
    m="$(openssl rand -hex 6)"
    guest "$g" sh -c "echo $m > /var/lib/iso-test/marker"
    key="$(guest "$g" cat /etc/ssh/ssh_host_ed25519_key.pub)"
    sbx stop "$g"
    check "grow refuses to shrink" refuses sbx grow "$g" --disk-gib 4
    check "8 -> 32 GiB grows offline" sbx grow "$g" --disk-gib 32
    boot "$g"
    check "the guest filesystem is 32 GiB" test "$(guest "$g" df -B1 --output=size / | tail -1 | xargs)" -ge $((31 * 1024 * 1024 * 1024))
    check "data and host key survive the grow" test "$(guest "$g" cat /var/lib/iso-test/marker)$(guest "$g" cat /etc/ssh/ssh_host_ed25519_key.pub)" = "$m$key"
    sbx stop "$g"
    # Same-sandbox races serialize in the runtime: of two identical grows,
    # exactly one applies; a start racing a grow either waits for it and boots
    # the grown disk, or wins and the grow is refused, never both.
    sbx grow "$g" --disk-gib 36 >/dev/null 2>&1 &
    g1=$!
    sbx grow "$g" --disk-gib 36 >/dev/null 2>&1 &
    g2=$!
    ok=0
    wait "$g1" && ok=$((ok + 1))
    wait "$g2" && ok=$((ok + 1))
    check "two concurrent grows of one sandbox apply once" test "$ok" -eq 1
    sbx grow "$g" --disk-gib 40 >/dev/null 2>&1 &
    g1=$!
    check "a start racing a grow boots" boot "$g"
    grew=0
    wait "$g1" && grew=1
    size="$(guest "$g" df -B1 --output=size / | tail -1 | xargs)"
    gib39=$((39 * 1024 * 1024 * 1024))
    serialized() { if ((grew)); then test "$size" -ge "$gib39"; else test "$size" -lt "$gib39"; fi; }
    check "start and grow serialize (grow $( ((grew)) && echo first || echo refused))" serialized
    sbx stop "$g"
    sbx delete "$g" --owner "$RUN"
fi

if want snapshots; then
    echo ""
    echo "=== Phase: snapshots ==="
    guest "$A" sh -c 'echo A > /var/lib/iso-test/state && docker volume create cp >/dev/null && docker run --rm -v cp:/v alpine:3.20 sh -c "echo A > /v/s"'
    mid="$(guest "$A" cat /etc/machine-id)"
    # Adversarial: a root guest disables its own `rm`; the identity reset must
    # not depend on the guest's tools.
    guest "$A" sh -c 'cp /usr/bin/rm /usr/bin/rm.iso-test && cp /usr/bin/true /usr/bin/rm && sync'
    sbx stop "$A"
    check "commit saves the stopped disk" sbx commit "$A" snap
    check "commit refuses an existing name without --replace" refuses sbx commit "$A" snap
    boot "$A"
    guest "$A" sh -c 'echo B > /var/lib/iso-test/state && docker run --rm -v cp:/v alpine:3.20 sh -c "echo B > /v/s" && echo x > /var/lib/iso-test/after && sync'
    sbx stop "$A"
    gen="$(sbx inspect "$A" | jq .record.diskGeneration)"
    check "restore replaces the disk" sbx restore "$A" snap
    check "restore bumps the disk generation" test "$(sbx inspect "$A" | jq .record.diskGeneration)" -gt "$gen"
    boot "$A"
    check "files and Docker volumes are back at the committed state" \
        test "$(guest "$A" cat /var/lib/iso-test/state)$(guest "$A" docker run --rm -v cp:/v alpine:3.20 cat /v/s)" = AA
    check "writes after the commit are gone" refuses guest "$A" test -e /var/lib/iso-test/after
    check "the restored disk generated a fresh identity, despite the guest's disabled rm" \
        test "$(guest "$A" cat /etc/machine-id)" != "$mid"
    guest "$A" sh -c 'cp /usr/bin/rm.iso-test /usr/bin/rm'
    c="$(name clone)"
    check "a new sandbox can be created from a committed disk" \
        sbx create "$c" --from-disk snap --cpus 2 --memory-mib 2048 --disk-gib 20 --owner "$RUN"
    boot "$c"
    check "it is grown to the requested size" test "$(guest "$c" df -B1 --output=size / | tail -1 | xargs)" -ge $((19 * 1024 * 1024 * 1024))
    check "it has its own identity" test "$(guest "$c" cat /etc/machine-id)" != "$mid"
    sbx stop "$c"
    sbx delete "$c" --owner "$RUN"
    sbx2 disk delete snap
    enroll "$A" 2>/dev/null || true
fi

if want recovery; then
    echo ""
    echo "=== Phase: recovery ==="
    r="$(name crash)"
    create "$r"
    # Owner killed during boot: a crashed state that start recovers.
    "$SANDBOX" run --root "$ROOT" "$r" >/dev/null 2>&1 &
    pid=$!
    sleep 0.3
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    sleep 1
    st="$(state "$r")"
    check "an owner killed during boot leaves a stopped or crashed sandbox" test "$st" = stopped -o "$st" = crashed
    check "start recovers it" boot "$r"
    # Owner killed while running: the VM dies with it and launchd respawns it.
    m="$(openssl rand -hex 4)"
    guest "$r" sh -c "echo $m > /var/lib/iso-test/crash && sync"
    old="$(sbx inspect "$r" | jq .live.pid)"
    kill -9 "$old"
    respawned=0
    for _ in $(seq 60); do
        now="$(sbx inspect "$r" | jq -r '.live.pid // empty')"
        [[ -n "$now" && "$now" != "$old" && "$(state "$r")" == running ]] && { respawned=1; break; }
        sleep 1
    done
    check "launchd respawns a killed owner" test "$respawned" = 1
    ready "$r"
    check "synced data survives the crash" test "$(guest "$r" cat /var/lib/iso-test/crash)" = "$m"
    # A client killed mid-stop does not stop the halt.
    "$SANDBOX" stop --root "$ROOT" "$r" >/dev/null 2>&1 &
    sleep 0.05
    kill -9 $! 2>/dev/null
    for _ in $(seq 100); do [[ "$(state "$r")" == stopped ]] && break; sleep 0.2; done
    sbx stop "$r" >/dev/null 2>&1
    check "a stop whose client was killed still ends stopped" test "$(state "$r")" = stopped
    # A create that never committed is removed by reconcile.
    mkdir -p "$ROOT/sandboxes/$(name half)"
    touch "$ROOT/sandboxes/$(name half)/rootfs.ext4"
    check "reconcile removes an uncommitted create" jq -e 'any(.action == "removed-uncommitted-create")' <<<"$(sbx reconcile)"
    check "delete refuses another owner" refuses sbx delete "$r" --owner someone-else
    check "delete removes the sandbox" sbx delete "$r" --owner "$RUN"

    # Interrupted mutations: SIGKILL the client of a grow, commit, or restore
    # at fractions of its uninterrupted duration, then reconcile. No staged
    # or scratch state may remain, and the record must describe the installed
    # disk
    # (docs/design/apple-sandbox-transactions.md INV-03, INV-04).
    t="$(name txn)"
    tdir="$ROOT/sandboxes/$t"
    create "$t"
    boot "$t"
    guest "$t" sh -c 'echo base > /var/lib/iso-test/txn && sync'
    sbx stop "$t"
    sbx commit "$t" txn-base >/dev/null
    rec() { sbx inspect "$t" | jq -r ".record.$1"; }
    # interrupt DELAY CMD...: run CMD, SIGKILL it after DELAY seconds, reconcile.
    interrupt() {
        local d="$1" pid
        shift
        "$@" >/dev/null 2>&1 &
        pid=$!
        sleep "$d"
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        sbx reconcile >/dev/null
    }
    settled() {
        [[ ! -e "$tdir/disk-update.pending.json" ]] &&
            [[ -z "$(find "$tdir" "$ROOT/disks" -maxdepth 1 \( -name '.update-*' -o -name '.tmp-*' -o -name '.pending-*' \
                -o -name '.grow-*' -o -name '.restore-*' -o -name '.maintenance-*' \) 2>/dev/null)" ]]
    }
    # The installed disk file: inode and size. `create` sizes it from the
    # image unpacker, so only a disk a grow or restore installed has exactly
    # the recorded size.
    disk() { stat -f '%i %z' "$tdir/rootfs.ext4"; }
    # installed APPLIED BEFORE: an applied update installed a new disk of the
    # recorded size; any other outcome left the previous disk in place.
    installed() {
        local now inode size
        now="$(disk)"
        read -r inode size <<<"$now"
        if (($1)); then
            test "${inode}" != "${2%% *}" -a "$size" = "$(rec diskBytes)"
        else
            test "$now" = "$2"
        fi
    }
    fs_matches_record() {
        local size
        size="$(guest "$t" df -B1 --output=size / | tail -1 | xargs)"
        test "${size:-0}" -ge $(($(rec diskBytes) * 95 / 100)) -a "${size:-0}" -le "$(rec diskBytes)"
    }

    ms="$(timed_ms sbx grow "$t" --disk-gib 9)"
    bad=""
    applied=0
    tries=0
    for f in $KILL_FRACTIONS; do
        d="$(delay_s "$ms" "$f")"
        tries=$((tries + 1))
        op="grow-$RUN-$tries"
        before="$(rec diskBytes)"
        file="$(disk)"
        target=$((before / 1073741824 + 2))
        interrupt "$d" "$SANDBOX" grow --root "$ROOT" "$t" --disk-gib "$target" --operation "$op"
        settled || bad+=" unsettled@$d"
        if [[ "$(rec lastOperation)" == "$op" ]]; then
            applied=$((applied + 1))
            [[ "$(rec diskBytes)" == $((target * 1073741824)) ]] || bad+=" record@$d"
            installed 1 "$file" || bad+=" disk@$d"
        else
            [[ "$(rec diskBytes)" == "$before" ]] || bad+=" record@$d"
            installed 0 "$file" || bad+=" disk@$d"
        fi
    done
    label="killed grows settle to the old or the new disk ($applied of $tries applied; uninterrupted ${ms} ms)"
    if [[ -z "$bad" ]]; then pass "$label"; else fail "$label" "$bad"; fi
    # Timed here, while the disk still holds the base content.
    restore_ms="$(timed_ms sbx restore "$t" txn-base)"
    check "the sandbox boots after the interrupted grows" boot "$t"
    check "its filesystem matches the recorded disk size" fs_matches_record
    guest "$t" sh -c 'echo newer > /var/lib/iso-test/txn && sync'
    sbx stop "$t"

    ms="$(timed_ms sbx commit "$t" txn-timed)"
    sbx2 disk delete txn-timed
    bad=""
    applied=0
    tries=0
    for f in $KILL_FRACTIONS; do
        d="$(delay_s "$ms" "$f")"
        tries=$((tries + 1))
        interrupt "$d" "$SANDBOX" commit --root "$ROOT" "$t" "txn-c$tries"
        settled || bad+=" unsettled@$d"
        disk="$ROOT/disks/txn-c$tries"
        if [[ -e "$disk.ext4" && -e "$disk.json" ]]; then
            applied=$((applied + 1))
            sbx2 disk delete "txn-c$tries"
        elif [[ -e "$disk.ext4" || -e "$disk.json" ]]; then
            bad+=" half-published@$d"
        fi
    done
    label="killed commits publish a whole disk or none ($applied of $tries applied; uninterrupted ${ms} ms)"
    if [[ -z "$bad" ]]; then pass "$label"; else fail "$label" "$bad"; fi

    ms="$restore_ms"
    bad=""
    applied=0
    tries=0
    for f in $KILL_FRACTIONS; do
        d="$(delay_s "$ms" "$f")"
        tries=$((tries + 1))
        op="restore-$RUN-$tries"
        gen="$(rec diskGeneration)"
        file="$(disk)"
        interrupt "$d" "$SANDBOX" restore --root "$ROOT" "$t" txn-base --operation "$op"
        settled || bad+=" unsettled@$d"
        if [[ "$(rec lastOperation)" == "$op" ]]; then
            applied=$((applied + 1))
            [[ "$(rec diskGeneration)" == $((gen + 1)) ]] || bad+=" generation@$d"
            # Not size: a restore keeps a committed disk's own size when it
            # needs no growth.
            [[ "$(disk | cut -d' ' -f1)" != "${file%% *}" ]] || bad+=" disk@$d"
        else
            [[ "$(rec diskGeneration)" == "$gen" ]] || bad+=" generation@$d"
            installed 0 "$file" || bad+=" disk@$d"
        fi
    done
    label="killed restores settle to the old or the new disk ($applied of $tries applied; uninterrupted ${ms} ms)"
    if [[ -z "$bad" ]]; then pass "$label"; else fail "$label" "$bad"; fi
    check "the sandbox boots after the interrupted restores" boot "$t"
    expected=newer
    ((applied > 0)) && expected=base
    check "its content is the $expected disk the record describes" test "$(guest "$t" cat /var/lib/iso-test/txn)" = "$expected"
    check "its filesystem matches the recorded disk size" fs_matches_record
    sbx stop "$t"
    check "an uninterrupted grow still applies" sbx grow "$t" --disk-gib $(($(rec diskBytes) / 1073741824 + 1))
    sbx delete "$t" --owner "$RUN"
    sbx2 disk delete txn-base
fi

if want concurrency; then
    echo ""
    echo "=== Phase: concurrency ==="
    # Each round boots COUNT sandboxes at once beside B, the fixed peer, so a
    # one-sandbox round still has a neighbour. Every new sandbox attacks B and
    # its ring successor, and B attacks the first, with the full peer probe.
    # Attackers run in parallel; each one's probes run in sequence.
    sbx stop "$A" >/dev/null 2>&1
    [[ "$(state "$B")" == running ]] || boot "$B"
    listeners "$B"
    for count in $CONCURRENCY; do
        names=()
        for ((i = 1; i <= count; i++)); do
            names+=("$(name "n${count}c$i")")
            create "$(name "n${count}c$i")" 2 1024 8
        done
        for n in "${names[@]}"; do sbx start "$n" >/dev/null & done
        wait
        all=1
        for n in "${names[@]}"; do ready "$n" || all=0; done
        check "$count at once: all boot" test "$all" = 1
        check "$count at once: each has its own address" \
            test "$( { ip4 "$B"; for n in "${names[@]}"; do ip4 "$n"; done; } | sort -u | wc -l | tr -d ' ')" = $((count + 1))
        check "$count at once: each has its own subnet" \
            test "$(for n in "$B" "${names[@]}"; do sbx inspect "$n" | jq -r '.effective.interfaces[0].network'; done | sort -u | wc -l | tr -d ' ')" = $((count + 1))
        for n in "${names[@]}"; do listeners "$n"; done
        out="$WORK/concurrency-$count"
        mkdir -p "$out"
        for ((i = 0; i < count; i++)); do
            (
                probe_pair "${names[i]}" "$B" >"$out/c$((i + 1))-B"
                if ((count > 1)); then
                    probe_pair "${names[i]}" "${names[(i + 1) % count]}" >"$out/c$((i + 1))-c$(((i + 1) % count + 1))"
                fi
            ) &
        done
        probe_pair "$B" "${names[0]}" >"$out/B-c1" &
        wait
        bad=""
        pairs=0
        for f in "$out"/*; do
            pairs=$((pairs + 1))
            isolated "$(<"$f")" || bad+=" ${f##*/}=$(<"$f")"
        done
        if [[ -z "$bad" ]]; then
            pass "$count at once: all $pairs directed pairs blocked on every vector, host reaches every target"
        else
            fail "$count at once: all $pairs directed pairs blocked on every vector, host reaches every target" \
                "attacker-target=reached|host misses|probes:$bad"
        fi
        for n in "${names[@]}"; do sbx stop "$n" >/dev/null; sbx delete "$n" --owner "$RUN"; done
    done
fi

if want iso; then
    echo ""
    echo "=== Phase: iso ==="
    # Free the host for iso's own sandbox.
    sbx stop "$A" >/dev/null 2>&1
    sbx stop "$B" >/dev/null 2>&1
    kernel="$(readlink -f "$HOME/Library/Application Support/com.apple.container/kernels/default.kernel-arm64")"
    # $1: extra apple_container settings as a JSON object.
    write_cfg() {
        jq -n --arg data "$CDATA" --arg binary "$SANDBOX" --arg builder "$CONTAINER" \
            --arg kernel "$kernel" --argjson extra "${1:-"{}"}" \
            '{data_dir: $data, github: "off",
              vm: {vcpu_count: 2, mem_size_mib: 2048, template_size_gib: 8},
              apple_container: ({binary: $binary, builder: $builder, kernel: $kernel} + $extra)}'
    }
    write_cfg >"$CCFG"
    write_cfg '{"boot_timeout_seconds": 15}' >"$CCFG_FAIL"
    mkdir -p "$WORK/project"
    echo "$RUN" >"$WORK/project/marker"
    if swift build --product iso --force-resolved-versions --scratch-path "$WORK/swift-build" \
        >"$WORK/iso-build.log" 2>&1 &&
        iso setup -y >"$WORK/iso-setup.log" 2>&1; then
        pass "iso setup builds, verifies, and publishes the image"
    else
        fail "iso setup builds, verifies, and publishes the image" "see $WORK/iso-build.log, $WORK/iso-setup.log"
        summary
    fi
    printf 'export FROM_ENV_FILE="from file"\nOVERRIDDEN=file\n' >"$WORK/e2e.env"
    if iso up "$WORK/project" --name e2e --no-agents --no-github --env-file "$WORK/e2e.env" \
        --env OVERRIDDEN=cli >"$WORK/iso-up.log" 2>&1; then
        pass "iso up creates and boots an instance"
    else
        fail "iso up creates and boots an instance" "see $WORK/iso-up.log"
        summary
    fi
    check "status reports running on the apple-container backend" \
        test "$(iso status e2e --json | jq -r '"\(.state) \(.backend)"')" = "running apple-container"
    check "the workspace is copied in" test "$(iso exec e2e -- cat /workspace/marker)" = "$RUN"
    # Positive control for the egress-none probes below: the same probe
    # succeeds from this open instance.
    check "egress open: the TCP probe reaches the Internet" \
        iso exec e2e -- timeout 5 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443'
    # shellcheck disable=SC2016 # Expand in the guest.
    check "--env-file values reach guest sessions, --env wins" \
        test "$(iso exec e2e -- sh -c 'echo "$FROM_ENV_FILE/$OVERRIDDEN"')" = "from file/cli"
    iso exec e2e -- sh -c 'echo before > ~/snap-before' >/dev/null
    check "iso stop stops the sandbox" iso stop e2e
    check "status reports stopped" test "$(cstate e2e)" = stopped
    check "iso start boots it again" iso start e2e --no-agents --no-github
    check "guest data survives stop/start" test "$(iso exec e2e -- sh -c 'cat ~/snap-before' 2>/dev/null)" = before

    # Secure Enclave secret store end to end (needs Touch ID, so opt-in):
    # generic references reach the guest, provider references never do, and
    # no host state holds a resolved value.
    if [[ "${ISO_TEST_SECRETS:-0}" == 1 ]]; then
        printf 'integration passphrase\n' >"$WORK/pass"
        chmod 600 "$WORK/pass"
        GENERIC="generic-$(openssl rand -hex 8)"
        PROVIDER="sk-provider-$(openssl rand -hex 8)"
        withpass() { ISO_SECRETS_PASSPHRASE_FD=3 iso "$@" 3<"$WORK/pass"; }
        check "iso secrets init creates the store" withpass secrets init --accept-no-recovery
        printf '%s' "$GENERIC" | ISO_SECRETS_PASSPHRASE_FD=3 "$ISO" --config "$CCFG" \
            secrets set generic --stdin 3<"$WORK/pass" >/dev/null 2>&1
        printf '%s' "$PROVIDER" | ISO_SECRETS_PASSPHRASE_FD=3 "$ISO" --config "$CCFG" \
            secrets set anthropic --stdin 3<"$WORK/pass" >/dev/null 2>&1
        check "iso secrets list shows names only" \
            test "$(withpass secrets list 2>/dev/null | cut -f1 | tr '\n' ' ')" = "anthropic generic "
        printf 'GENERIC={vault:generic}\nANTHROPIC_API_KEY={vault:anthropic}\n' >"$WORK/vault.env"
        iso stop e2e >/dev/null 2>&1
        check "iso start resolves --env-file references" \
            withpass start e2e --no-agents --no-github --env-file "$WORK/vault.env"
        # shellcheck disable=SC2016 # Expand in the guest.
        check "a generic reference reaches guest sessions" \
            test "$(withpass exec e2e -- sh -c 'echo "$GENERIC"' 2>/dev/null)" = "$GENERIC"
        # shellcheck disable=SC2016 # Expand in the guest.
        check "a provider reference never reaches the guest" \
            test "$(withpass exec e2e -- sh -c 'echo "${ANTHROPIC_API_KEY:-unset}"' 2>/dev/null)" = unset
        # Instance JSON and the store only: disk images are large and sparse.
        check "guest_env.json holds references, not values" \
            refuses grep -qsE "$GENERIC|$PROVIDER" "$CSTATE"/instances/*/*.json "$CDATA"/secrets/*
        check "no host log holds a resolved value" \
            refuses grep -rqsE "$GENERIC|$PROVIDER" "$WORK"/*.log
        # Later checks run without a passphrase: drop the saved references.
        rm -f "$CSTATE/instances/e2e/guest_env.json"
    else
        skip "secret store end to end (set ISO_TEST_SECRETS=1; needs Touch ID)"
    fi

    # Staged pull: guest changes reach the project only on --apply, and an
    # escaping symlink makes the stage inapplicable.
    iso exec e2e -- sh -c 'echo guest > /workspace/marker && mkdir -p /workspace/new && echo n > /workspace/new/f' >/dev/null
    review="$(iso diff e2e 2>/dev/null)"
    check "iso diff lists the guest's changes" grep -q '^  M marker' <<<"$review"
    check "iso diff leaves the project untouched" test "$(cat "$WORK/project/marker")" = "$RUN"
    stage_id="$(sed -n 's/^Stage \([0-9a-f]*\) .*/\1/p' <<<"$review")"
    check "iso pull --apply applies the reviewed stage" iso pull e2e --apply --stage-id "$stage_id"
    check "the applied change reached the project" test "$(cat "$WORK/project/marker")" = guest
    check "the applied stage is removed" test ! -e "$CSTATE/instances/e2e/stage"
    iso exec e2e -- ln -s /etc/passwd /workspace/escape >/dev/null
    check "a stage with an escaping symlink is inapplicable" \
        grep -q 'cannot be applied' <<<"$(iso diff e2e --stat 2>/dev/null)"
    check "iso pull --apply refuses it" refuses iso pull e2e --apply
    check "iso pull --discard removes the stage" iso pull e2e --discard
    check "the escape did not reach the project" test ! -e "$WORK/project/escape"
    iso exec e2e -- rm /workspace/escape >/dev/null

    # What iso's own sandbox exposes, with a live agent and the canary in
    # iso's environment.
    mid="$(machine_id e2e)"
    eff="$(csbx inspect "$mid" | jq .effective)"
    check "iso's sandbox: kernel pseudo-filesystems only" \
        jq -e '[.mounts[] | select(.type | IN("proc","sysfs","devtmpfs","mqueue","tmpfs","cgroup2","devpts") | not)] | length == 0' <<<"$eff"
    check "iso's sandbox: no relays, ports, or agent forwarding" \
        jq -e '.socketRelays == 0 and .publishedPorts == 0 and .sshAgentForwarding == false' <<<"$eff"
    mi="$(iso exec e2e -- cat /proc/self/mountinfo)"
    check "iso's guest: no file-sharing mounts or host paths" \
        refuses grep -Eq ' - (virtiofs|9p|fuse|fuse\.[^ ]+|nfs4?|cifs|smb3?|smbfs) |/Users/' <<<"$mi"
    # shellcheck disable=SC2016 # Expand in the guest.
    agent="$(
        eval "$(ssh-agent -s)" >/dev/null
        iso exec e2e -- sh -c 'echo ${SSH_AUTH_SOCK:-none}'
        ssh-agent -k >/dev/null
    )"
    check "iso exec forwards no host agent" test "$agent" = none
    # The pattern splits the canary with an empty group: sudo logs its
    # command line to the guest journal, which must not be a match.
    pattern="${CANARY:0:24}()${CANARY:24}"
    leaks="$(iso exec e2e -- sudo sh -c "grep -rlsE '$pattern' / --exclude-dir=proc --exclude-dir=sys --exclude-dir=dev | head -3
        cat /proc/[0-9]*/environ 2>/dev/null | tr '\0' '\n' | grep -cE '$pattern'")"
    if [[ "$leaks" == 0 ]]; then
        pass "the canary in iso's environment reaches no guest file or process"
    else
        fail "the canary in iso's environment reaches no guest file or process" "$(tr '\n' ' ' <<<"$leaks")"
    fi

    # Pinned identity: iso refuses a guest whose host key changed, both on a
    # live connection and at the next start.
    iso exec e2e -- sudo sh -c 'cp -a /etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key.pub /root/ &&
        rm -f /etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key.pub &&
        ssh-keygen -q -t ed25519 -N "" -f /etc/ssh/ssh_host_ed25519_key && systemctl restart ssh' >/dev/null 2>&1
    check "iso exec refuses a changed host key" refuses iso exec e2e -- true
    iso stop e2e >/dev/null 2>&1
    changed="$(iso start e2e --no-agents --no-github 2>&1)"
    check "iso start refuses a changed host key" grep -q APPLE_HOST_KEY_CHANGED <<<"$changed"
    check "the refused start leaves the sandbox stopped" test "$(csbx inspect "$mid" | jq -r .status)" = stopped
    # repair CMD...: run CMD as root over the runtime's own channel, which
    # needs no SSH, with the sandbox stopped before and after.
    repair() {
        csbx start "$mid" >/dev/null
        for _ in $(seq 100); do csbx exec "$mid" -- true >/dev/null 2>&1 && break; sleep 0.2; done
        csbx exec "$mid" -- "$@" >/dev/null 2>&1
        csbx stop "$mid" >/dev/null
    }
    repair cp -a /root/ssh_host_ed25519_key /root/ssh_host_ed25519_key.pub /etc/ssh/
    check "the pinned key restored, iso starts again" iso start e2e --no-agents --no-github

    # sshd will not start on the next boot, so a restart after a resize fails.
    iso exec e2e -- sudo systemctl mask ssh.service ssh.socket >/dev/null 2>&1
    iso stop e2e >/dev/null 2>&1
    check "resize --mem/--vcpus records the change" iso resize e2e --mem 3072 --vcpus 3
    check "the runtime record holds the new memory" test "$(record e2e memoryBytes)" = $((3072 * 1024 * 1024))
    check "a failed resize --start is refused" \
        refuses "$ISO" --config "$CCFG_FAIL" resize e2e --mem 4096 --start
    check "the failed restart leaves the sandbox stopped" test "$(csbx inspect "$(machine_id e2e)" | jq -r .status)" = stopped
    check "the failed restart rolls the memory back" test "$(record e2e memoryBytes)" = $((3072 * 1024 * 1024))
    check "no journal is left behind" test ! -e "$CSTATE/instances/e2e/operation.json"
    repair systemctl unmask ssh.service ssh.socket
    resize_ms="$(timed_ms iso resize e2e --size 12)"
    check "resize --size grows the disk" test "$(record e2e diskBytes)" = $((12 * 1073741824))
    check "start after the resizes succeeds" iso start e2e --no-agents --no-github
    check "the guest sees the new vCPU count (+1 runtime vCPU)" test "$(iso exec e2e -- nproc)" = 4
    size="$(iso exec e2e -- df -B1 --output=size / | tail -1 | xargs)"
    check "the guest sees the grown disk" test "${size:-0}" -ge $((12 * 1024 * 1024 * 1024 * 95 / 100))

    iso stop e2e >/dev/null 2>&1
    check "iso commit saves an image" iso commit e2e --image e2e-snap
    iso start e2e --no-agents --no-github >/dev/null 2>&1
    iso exec e2e -- sh -c 'echo after > ~/snap-after' >/dev/null
    iso stop e2e >/dev/null 2>&1
    gen="$(record e2e diskGeneration)"
    restore_ms="$(timed_ms iso restore e2e --image e2e-snap)"
    check "iso restore replaces the disk" test "$(record e2e diskGeneration)" -gt "$gen"
    check "start after restore re-pins the new host key" iso start e2e --no-agents --no-github
    check "restore keeps data from before the commit" test "$(iso exec e2e -- sh -c 'cat ~/snap-before' 2>/dev/null)" = before
    check "restore drops data written after the commit" \
        test "$(iso exec e2e -- sh -c 'test -e ~/snap-after && echo present || echo absent')" = absent

    # Interrupted iso mutations: SIGKILL iso and its runtime client partway
    # through; the next start reconciles iso's journal with the runtime.
    # kill_iso DELAY ARGS...: run iso ARGS, kill it and its children after DELAY.
    kill_iso() {
        local d="$1" pid
        shift
        "$ISO" --config "$CCFG" "$@" </dev/null >/dev/null 2>&1 &
        pid=$!
        sleep "$d"
        pkill -9 -P "$pid" 2>/dev/null
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    }
    gib=12
    for f in $ISO_KILL_FRACTIONS; do
        for op in restore resize; do
            iso stop e2e >/dev/null 2>&1
            if [[ "$op" == restore ]]; then
                d="$(delay_s "$restore_ms" "$f")"
                kill_iso "$d" restore e2e --image e2e-snap
            else
                d="$(delay_s "$resize_ms" "$f")"
                gib=$((gib + 1))
                kill_iso "$d" resize e2e --size "$gib"
            fi
            check "a $op killed after ${d}s: the next start recovers" iso start e2e --no-agents --no-github
            check "a $op killed after ${d}s: no journal is left" test ! -e "$CSTATE/instances/e2e/operation.json"
            check "a $op killed after ${d}s: pinned SSH works" test "$(iso exec e2e -- echo ok 2>/dev/null)" = ok
            size="$(iso exec e2e -- df -B1 --output=size / | tail -1 | xargs)"
            check "a $op killed after ${d}s: the filesystem matches the record" \
                test "${size:-0}" -ge $(($(record e2e diskBytes) * 95 / 100))
        done
    done

    # A disk-generation increase iso did not make does not authorize a new
    # host key (INV-07): an out-of-band restore resets the guest's identity.
    iso stop e2e >/dev/null 2>&1
    mid="$(machine_id e2e)"
    csbx commit "$mid" oob >/dev/null && csbx restore "$mid" oob >/dev/null
    check "iso start refuses a restore it did not make" refuses iso start e2e --no-agents --no-github
    check "that refused start leaves the sandbox stopped" test "$(csbx inspect "$mid" | jq -r .status)" = stopped
    "$SANDBOX" disk delete --root "$CROOT" oob >/dev/null 2>&1

    # egress none: a host-only sandbox keeps SSH but has no route beyond the
    # host and no resolver; an `open` configuration refuses to hand it out.
    jq '. + {egress: "none"}' "$CCFG" >"$WORK/iso-none.jsonc"
    none() { "$ISO" --config "$WORK/iso-none.jsonc" "$@" </dev/null; }
    mkdir -p "$WORK/project-none"
    if none up "$WORK/project-none" --name e2e-none --no-agents --no-github >"$WORK/iso-up-none.log" 2>&1; then
        pass "egress none: iso up creates and boots a host-only instance"
        check "egress none: the runtime records host_only" \
            test "$(csbx inspect "$(machine_id e2e-none)" | jq -r .record.network)" = host_only
        check "egress none: guest SSH works" test "$(none exec e2e-none -- echo ok 2>/dev/null)" = ok
        check "egress none: no TCP to the Internet" \
            refuses none exec e2e-none -- timeout 5 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443'
        check "egress none: no DNS resolution" \
            refuses none exec e2e-none -- timeout 5 getent hosts example.com
        check "egress none: an open configuration refuses the instance" refuses iso exec e2e-none -- true
        none destroy e2e-none >/dev/null 2>&1
    else
        fail "egress none: iso up creates and boots a host-only instance" "see $WORK/iso-up-none.log"
    fi

    # Session TTL: the owner halts the VM at the deadline on its own.
    jq '. + {limits: {session_ttl: 60}}' "$CCFG" >"$WORK/iso-ttl.jsonc"
    ttl() { "$ISO" --config "$WORK/iso-ttl.jsonc" "$@" </dev/null; }
    mkdir -p "$WORK/project-ttl"
    if ttl up "$WORK/project-ttl" --name e2e-ttl --no-agents --no-github >"$WORK/iso-up-ttl.log" 2>&1; then
        check "session ttl: the runtime records the deadline" \
            test "$(csbx inspect "$(machine_id e2e-ttl)" | jq -r '.record.expiresAt != null')" = true
        for _ in $(seq 60); do
            [[ "$(csbx inspect "$(machine_id e2e-ttl)" | jq -r .status)" == stopped ]] && break
            sleep 2
        done
        check "session ttl: the VM stops itself at the deadline" \
            test "$(csbx inspect "$(machine_id e2e-ttl)" | jq -r .status)" = stopped
        check "session ttl: iso start begins a new session" ttl start e2e-ttl --no-agents --no-github
        ttl destroy e2e-ttl >/dev/null 2>&1
    else
        fail "session ttl: iso up boots the instance" "see $WORK/iso-up-ttl.log"
    fi

    check "iso audit shows the recorded boots" grep -q '"event":"boot"' <<<"$(iso audit e2e 2>/dev/null)"
    check "iso audit --suggest-config is advisory JSONC" \
        grep -q "Advisory only" <<<"$(iso audit e2e --suggest-config 2>/dev/null)"

    check "iso destroy removes the instance" iso destroy e2e
    check "the runtime has no sandbox left" test "$(csbx list | jq length)" = 0
    check "the instance state is gone" test ! -e "$CSTATE/instances/e2e"
    check "the committed image can be deleted" iso images --delete e2e-snap
fi

# Guarded local inference (docs/design/secure-local-inference-spec.md §15):
# a real VM under `inference.mode = "required"` and `egress: "none"` reaches
# two scripted host backends only through the iso-inference gateway. Uses the
# per-user gateway location and stops that gateway at the end, so no other
# iso-inference may be running for this user.
if want inference; then
    echo ""
    echo "=== Phase: inference ==="
    kernel="$(readlink -f "$HOME/Library/Application Support/com.apple.container/kernels/default.kernel-arm64")"
    ICFG="$WORK/iso-inference.jsonc"
    iinf() { "$ISO" --config "$ICFG" "$@" </dev/null; }
    free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
    port_a="$(free_port)"
    port_r="$(free_port)"
    log_a="$WORK/backend-anthropic.jsonl"
    log_r="$WORK/backend-responses.jsonl"
    : >"$log_a"
    : >"$log_r"
    python3 tests/fixtures/inference-backend.py anthropic-messages 127.0.0.1 "$port_a" "$log_a" &
    backend_a=$!
    python3 tests/fixtures/inference-backend.py openai-responses 127.0.0.1 "$port_r" "$log_r" &
    backend_r=$!
    # $1: extra top-level settings as a JSON object; $2: the anthropic backend port.
    write_inference_cfg() {
        jq -n --arg data "$CDATA" --arg binary "$SANDBOX" --arg builder "$CONTAINER" \
            --arg kernel "$kernel" --argjson pa "$2" --argjson pr "$port_r" --argjson extra "$1" '
            def profile($p): {protocol: $p, completion_evidence: "drain", context_overflow: "reject",
              input_overhead: {per_request_bytes: 4096, per_message_bytes: 64},
              max_input_bytes: "2MiB"};
            {data_dir: $data, github: "off", egress: "none",
             vm: {vcpu_count: 2, mem_size_mib: 2048, template_size_gib: 8},
             apple_container: {binary: $binary, builder: $builder, kernel: $kernel},
             inference: {mode: "required",
               qualification_profiles: {anthropic: profile("anthropic-messages"),
                                        responses: profile("openai-responses")},
               backends: {
                 "fake-anthropic": {base_url: "http://127.0.0.1:\($pa)", protocol: "anthropic-messages",
                                    qualification_profile: "anthropic"},
                 "fake-responses": {base_url: "http://127.0.0.1:\($pr)", protocol: "openai-responses",
                                    qualification_profile: "responses"}},
               services: {
                 "local-claude": {backend: "fake-anthropic", upstream_model: "fake/claude-upstream",
                                  frontend_apis: ["anthropic-messages"], max_context_tokens: 200000},
                 "local-codex": {backend: "fake-responses", upstream_model: "fake/codex-upstream",
                                 frontend_apis: ["openai-responses"], max_context_tokens: 200000}}},
             claude: {config_dir: false, local_model: {service: "local-claude"}},
             codex: {config_dir: false, local_model: {service: "local-codex"}}} + $extra'
    }
    write_inference_cfg '{}' "$port_a" >"$ICFG"
    if [[ ! -x "$ISO" ]]; then
        swift build --product iso --force-resolved-versions --scratch-path "$WORK/swift-build" \
            >"$WORK/iso-build.log" 2>&1 || fail "inference: iso builds" "see $WORK/iso-build.log"
    fi
    if swift build --package-path iso-proxy --product iso-inference --force-resolved-versions \
        --scratch-path "$WORK/proxy-build" >"$WORK/inference-build.log" 2>&1 &&
        cp "$WORK/proxy-build/debug/iso-inference" "$(dirname "$ISO")/iso-inference" &&
        iinf setup -y >"$WORK/inference-setup.log" 2>&1; then
        pass "inference: iso-inference builds beside iso and the image is ready"
    else
        fail "inference: iso-inference builds beside iso and the image is ready" \
            "see $WORK/inference-build.log, $WORK/inference-setup.log"
    fi
    mkdir -p "$WORK/project-inf"
    if ANTHROPIC_API_KEY="$CANARY" OPENAI_API_KEY="$CANARY" \
        iinf up "$WORK/project-inf" --name inf --no-github >"$WORK/iso-up-inf.log" 2>&1; then
        pass "inference: iso up boots with agents under inference.mode required"
        state="$(iinf inference status inf --json)"
        check "inference: the gateway reports one active session" \
            test "$(jq -r '[.sessions[] | select(.state == "active")] | length' <<<"$state")" = 1
        check "inference: status names the unverified backend isolation" \
            test "$(jq -r '[.backends[].backend_isolation_verified] | unique | .[0]' <<<"$state")" = false
        check "inference: no provider credential reaches the guest" \
            refuses grep -q "$CANARY" <<<"$(iinf exec inf -- env 2>/dev/null)"
        # shellcheck disable=SC2016 # Expand in the guest.
        token="$(iinf exec inf -- sh -c 'grep -o "\"ANTHROPIC_AUTH_TOKEN\": *\"[0-9a-f]*\"" ~/.claude/settings.json | grep -o "[0-9a-f]\{64\}"' 2>/dev/null)"
        check "inference: Claude's managed settings carry a 64-hex capability" test "${#token}" = 64
        body='{"model":"local-claude","max_tokens":64000,"messages":[{"role":"user","content":"hi"}],"stream":true}'
        code_anon="$(iinf exec inf -- curl -s -o /dev/null -w '%{http_code}' -H 'content-type: application/json' \
            -d "$body" http://127.0.0.1:10788/v1/messages 2>/dev/null)"
        check "inference: a request without the capability is refused (401)" test "$code_anon" = 401
        before="$(wc -l <"$log_a" | tr -d ' ')"
        reply="$(iinf exec inf -- curl -s -H "authorization: Bearer $token" -H 'content-type: application/json' \
            -d "$body" 'http://127.0.0.1:10788/v1/messages?beta=true' 2>/dev/null)"
        check "inference: an authorized request streams the backend's reply under the alias" \
            grep -q '"model":"local-claude"' <<<"$reply"
        check "inference: the upstream model id never reaches the guest" \
            refuses grep -q "fake/claude-upstream" <<<"$reply"
        last="$(tail -1 "$log_a")"
        check "inference: the backend received the host-selected model and a clamped limit" \
            test "$(jq -r '"\(.body.model) \(.body.max_tokens) \(.body.stream)"' <<<"$last")" = "fake/claude-upstream 8192 true"
        denied="$(iinf exec inf -- curl -s -o /dev/null -w '%{http_code}' -H "authorization: Bearer $token" \
            -H 'content-type: application/json' \
            -d '{"model":"local-claude","max_tokens":10,"messages":[],"draft_model":"x"}' \
            http://127.0.0.1:10788/v1/messages 2>/dev/null)"
        check "inference: a host-selected field is refused (403) before the backend" test "$denied" = 403
        check "inference: only the authorized request reached the backend" \
            test "$(wc -l <"$log_a" | tr -d ' ')" = $((before + 1))
        # shellcheck disable=SC2016 # Expand in the guest.
        host_ip="$(iinf exec inf -- sh -c 'ip -4 -o addr show eth0 | awk "{print \$4}" | cut -d/ -f1 | sed "s/\.[0-9]*$/.1/"' 2>/dev/null)"
        check "inference: the backend is not reachable directly from the guest" \
            refuses iinf exec inf -- timeout 5 bash -c "exec 3<>/dev/tcp/$host_ip/$port_a"
        claude_out="$(iinf exec inf -- sh -c 'cd /tmp && timeout 180 ~/.local/bin/claude -p "say ok" 2>&1' 2>/dev/null)"
        check "inference: Claude Code completes a turn through the gateway" grep -qx "ok" <<<"$claude_out"
        codex_out="$(iinf exec inf -- sh -c 'cd /tmp && timeout 180 codex exec --skip-git-repo-check "say ok" </dev/null 2>&1' 2>/dev/null)"
        check "inference: Codex completes a turn through the gateway" grep -q "^ok$" <<<"$codex_out"
        check "inference: Codex asked for the host-selected model" \
            grep -q '"model": "fake/codex-upstream"' <<<"$(jq -c . "$log_r" | sed 's/"model":/"model": /g')"
        # The forward's exit revokes the session; the next session re-registers.
        fwd="$(cat "$CSTATE/instances/inf/proxy-inference-fwd.pid" 2>/dev/null)"
        [[ -n "$fwd" ]] && kill "$fwd" 2>/dev/null
        sleep 2
        check "inference: killing the forward revokes the session" \
            test "$(iinf inference status inf --json | jq -r '[.sessions[] | select(.state == "active")] | length')" = 0
        check "inference: the next command establishes a fresh session" \
            test "$(iinf exec inf -- echo ok 2>/dev/null)" = ok
        check "inference: the old capability no longer works" \
            test "$(iinf exec inf -- curl -s -o /dev/null -w '%{http_code}' -H "authorization: Bearer $token" \
                -H 'content-type: application/json' -d "$body" http://127.0.0.1:10788/v1/messages 2>/dev/null)" = 401
        check "inference: iso inference revoke removes the session" iinf inference revoke inf
        check "inference: a revoked VM still runs commands" test "$(iinf exec inf -- echo ok 2>/dev/null)" = ok
        check "inference: and stays without a session" \
            test "$(iinf inference status inf --json | jq -r '.sessions | length')" = 0
        check "inference: iso stop succeeds" iinf stop inf
        # A backend that also listens beyond loopback fails the start.
        kill "$backend_a" 2>/dev/null
        wait "$backend_a" 2>/dev/null
        python3 tests/fixtures/inference-backend.py anthropic-messages 0.0.0.0 "$port_a" "$log_a" &
        backend_a=$!
        # Wait for the listener: a start before it exists fails as unavailable.
        for _ in $(seq 100); do
            python3 -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 0.2)' \
                "$port_a" 2>/dev/null && break
            sleep 0.1
        done
        check "inference: a backend bound beyond loopback refuses the start" refuses iinf start inf --no-github
        unsafe_start="$("$ISO" --config "$ICFG" start inf --no-github 2>&1 </dev/null)"
        check "inference: and says why" grep -q INFERENCE_BACKEND_UNSAFE_BIND <<<"$unsafe_start"
        grep -q INFERENCE_BACKEND_UNSAFE_BIND <<<"$unsafe_start" \
            || printf '%s\n' "$unsafe_start" | tail -5 >&2
        check "inference: doctor reports the unsafe bind" refuses iinf inference doctor
        iinf destroy inf >/dev/null 2>&1
    else
        fail "inference: iso up boots with agents under inference.mode required" "see $WORK/iso-up-inf.log"
    fi
    kill "$backend_a" "$backend_r" 2>/dev/null
    iinf inference stop --force >/dev/null 2>&1
    rm -f "$(dirname "$ISO")/iso-inference"
fi

summary
