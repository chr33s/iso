# Mac-to-Mac validation runbook

## Status and purpose

**The real Apple VM gates in this runbook have not been executed.** The delivery environment is Linux, not a supported `iso` VM host. The accompanying `probe.py` was run here and correctly returned `unsupported_platform` with exit code 2. It did not test runtime availability or isolation.

This runbook has two stages: establish what the unchanged source baseline can do over management SSH; then test the proposed host-control implementation against real VMs. The runnable Python prototype in `../prototype/` tests protocol and state-machine behavior with simulated VMs. Its success cannot substitute for these Apple, SSH, broker, and process-lifetime gates.

Baseline: [`chr33s/iso` at `47d17ba2524b145b229abcf42c85f8b5f0071e65`](https://github.com/chr33s/iso/tree/47d17ba2524b145b229abcf42c85f8b5f0071e65). Commands below are either explicitly marked **baseline** or **candidate, not yet implemented**. No upstream repository change or real remote operation was made in preparing this runbook.

## 1. Test boundary and evidence

Use one dedicated worker account on an Apple Silicon Mac and a separate client Mac. The worker must have macOS 27+, Xcode 27/Swift 6.4, a runtime built from the selected snapshot, and stock Apple `container` 1.4.1+ for image building. The supported host minimum differs from the underlying vmnet API minimum. Source: [backend prerequisites and qualification](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/docs/backends.md#L24-L49).

Every real VM experiment uses a new private fixture root, a synthetic project, a dedicated image, and an explicit instance name. Start with a worker account without provider secrets or user project files. Do not point a fixture at an existing `~/.iso` installation. Keep the resulting fixture until its exact VM IDs have been accounted for and explicitly stopped/destroyed. A failed or unreachable operation is unresolved evidence, not permission to remove its files.

Keep one evidence record per gate containing:

- Source commit and candidate commit, binary hashes, OS/build versions, runtime version/protocol, and builder version.
- UTC start/end times, worker boot-session UUID, claimed login stage, and the operator's login/reboot timeline.
- Host/owner/instance/runtime IDs, boot ID, policy hash/generation, operation ID, and session ID where the implementation exposes them.
- The exact command or structured request, its exit status, parsed response, and bounded diagnostics. No credential values, private keys, capability tokens, or full process environments.
- The expected outcome, observed outcome, and `passed`, `failed`, or `not_run` disposition. Record a missing prerequisite as blocked, never passed.

The environment probe deliberately omits config, keychain, file inventory, user process listings, runtime execution, and network access. It invokes only fixed system queries and emits selected version/status fields. A console-owner check or GUI-domain query cannot establish that nobody logged in earlier during the boot; the operator timeline supplies that evidence.

## 2. Pinned management connection and read-only preflight

Prepare a dedicated client SSH alias whose management-host key has been verified through an independent trusted channel. Use a dedicated identity, `StrictHostKeyChecking yes`, `IdentitiesOnly yes`, `ForwardAgent no`, `ClearAllForwardings yes`, `BatchMode yes`, and a fixture-specific `UserKnownHostsFile`. Do not enable trust-on-first-use as part of this test. A host-key change is a test failure requiring an explicit enrollment decision.

**Available now: read-only probe.** On the worker directly:

```bash
/usr/bin/python3 /absolute/path/mac-validation/probe.py --stage preparation
```

Or send the reviewed script over the pinned management connection. The remote command is fixed; script contents travel on stdin:

```bash
/usr/bin/ssh -F /absolute/path/iso-qa-ssh-config -T iso-qa-worker \
  /usr/bin/python3 - --stage fresh_boot_before_gui < mac-validation/probe.py
```

Python must already exist at that approved absolute path. The probe itself does not install it or contact a host. Exit 0 means only `eligible_for_live_validation`; 2 means a platform/tool requirement was not met; 3 means required observations were incomplete. Even exit 0 leaves runtime qualification, image setup, VM creation, guest routing, TTL, and isolation untested.

Before the first-ever GUI login of the dedicated test account, capture this preflight and then run the baseline below over SSH. If initial developer-tool or builder provisioning requires an interactive login, record that limitation and establish a separate account or boot for the never-logged-in gate. Do not relabel a locked GUI session as an SSH-only initial boot.

## 3. Baseline: build exact binaries and create isolated state

These commands exist at the pinned source snapshot. Run them on the prepared worker, in a clean dedicated checkout, using an approved Python 3 interpreter. `build-release.py` produces all five matching executables and checks the exact clean revision when `--expected-revision` is supplied. Sources: [release build entrypoint](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/docs/getting-started.md#L59-L85), [archive naming and revision gate](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/scripts/build-release.py#L208-L240).

```bash
cd /Users/isoqa/src/iso
git checkout --detach 47d17ba2524b145b229abcf42c85f8b5f0071e65
python3 scripts/build-release.py --release \
  --expected-revision 47d17ba2524b145b229abcf42c85f8b5f0071e65
```

Use the actual dedicated account's home instead of `/Users/isoqa` if different. The following creates a new fixture and extracts only the archive just built; it does not replace installed binaries. Retain the printed root path in the evidence manifest so subsequent SSH sessions use the same fixture.

```bash
set -euo pipefail
umask 077
iso_fixture_root="$(/usr/bin/mktemp -d /Users/isoqa/iso-remote-validation.XXXXXXXX)"
/bin/mkdir "$iso_fixture_root/bin" "$iso_fixture_root/project" "$iso_fixture_root/evidence"
/usr/bin/tar -xzf \
  /Users/isoqa/src/iso/.build/release-archive/iso-47d17ba2524b-aarch64-apple-darwin.tar.gz \
  -C "$iso_fixture_root/bin" --strip-components 1
iso_bin="$iso_fixture_root/bin/iso"
iso_runtime_bin="$iso_fixture_root/bin/iso-sandbox"
iso_builder_bin='/opt/homebrew/bin/container'
python3 - "$iso_fixture_root" "$iso_runtime_bin" "$iso_builder_bin" <<'PY'
import json
import pathlib
import sys
root, runtime, builder = sys.argv[1:]
p = pathlib.Path(root)
assert p.is_absolute() and p.is_dir() and not p.is_symlink()
assert pathlib.Path(runtime).is_file() and pathlib.Path(builder).is_file()
config = {
    "data_dir": str(p / "data"),
    "github": "off",
    "claude": {"config_dir": False, "env_forward": []},
    "codex": {"config_dir": False, "env_forward": []},
    "guest_env": {},
    "updates": {"mode": "off"},
    "limits": {"session_ttl": "10m"},
    "vm": {"vcpu_count": 2, "mem_size_mib": 4096, "template_size_gib": 8},
    "apple_container": {"binary": runtime, "builder": builder},
}
(p / "config.json").write_text(json.dumps(config, indent=2) + "\n")
(p / "project" / "sentinel.txt").write_text("iso remote validation fixture\n")
(p / "fixture.json").write_text(json.dumps({
    "purpose": "iso-remote-validation", "root": root,
    "instance_name": "remote-qa", "image_name": "remote-qa-base"
}, indent=2) + "\n")
print(root)
PY
```

If the builder is installed at `/usr/local/bin/container`, set that approved path before generating config. Do not discover an executable through project-controlled `PATH`. `data_dir` and explicit binary paths are existing config fields; `--config` must identify an existing file. Sources: [state and custom root](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/docs/backends.md#L74-L96), [VM config fields](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/docs/configuration.md#L213-L221).

### Baseline version and setup gate

```bash
"$iso_bin" capabilities --output json > "$iso_fixture_root/evidence/capabilities.json"
"$iso_runtime_bin" version > "$iso_fixture_root/evidence/runtime-version.json"
python3 - "$iso_fixture_root/evidence/runtime-version.json" <<'PY'
import json
import sys
v = json.load(open(sys.argv[1]))
assert (v["name"], v["protocol"], v["containerization"]) == (
    "iso-sandbox", 5, "0.45.0"
), v
PY
```

`capabilities` is side-effect free and does not establish runtime or service readiness. Runtime `version` prints JSON with `name`, `version`, `protocol`, `containerization`, and optional `features`. Its success establishes an advertised version, not a boot or isolation proof. Sources: [capabilities contract](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/docs/machine-interface.md#L137-L154), [runtime version command](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/iso-sandbox/Sources/IsoSandbox/CLI.swift#L30-L43).

The operator must have prepared the builder service. Its existing startup command is `"$iso_builder_bin" system start`; `iso` does not start it itself. Record whether this works in each SSH/login stage. Run setup as the same worker identity that will own the VM:

```bash
"$iso_bin" setup --config "$iso_fixture_root/config.json" \
  --image remote-qa-base --no-devcontainer \
  > "$iso_fixture_root/evidence/setup.stdout" \
  2> "$iso_fixture_root/evidence/setup.stderr"
```

Do not add `--output json` to setup; it is outside the existing machine-output command set. Setup resolves and qualifies the runtime, initializes pinned kernel/init assets, builds/imports the image on this worker, and verifies a disposable VM before recording the image. The builder may use network access for these build inputs. Source: [setup process](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/docs/backends.md#L105-L119).

**Pass:** exact expected runtime advertisement; setup exit 0; dedicated image record and a successful verification boot; no unaccounted verification VM. The presence of five executable files alone is insufficient.

## 4. Baseline: real VM, native identity, and lifecycle

Run all commands on the worker through pinned management SSH. They remain worker-local commands; they do not implement client-side host selection.

```bash
"$iso_bin" up "$iso_fixture_root/project" --config "$iso_fixture_root/config.json" \
  --name remote-qa --image remote-qa-base \
  --no-agents --no-github --no-prompt --no-devcontainer --output json \
  > "$iso_fixture_root/evidence/up.json"
"$iso_bin" status remote-qa --config "$iso_fixture_root/config.json" --output json \
  > "$iso_fixture_root/evidence/status.json"
"$iso_bin" exec remote-qa --config "$iso_fixture_root/config.json" \
  -- /bin/cat /workspace/sentinel.txt
iso_fixture_runtime="$iso_fixture_root/data/backends/apple-container-v1/runtime"
"$iso_runtime_bin" list --root "$iso_fixture_runtime" \
  > "$iso_fixture_root/evidence/runtime-list.json"
iso_fixture_id="$(python3 - "$iso_fixture_root/evidence/runtime-list.json" <<'PY'
import json
import re
import sys
records = json.load(open(sys.argv[1]))
assert len(records) == 1, "Expected exactly the dedicated fixture VM; investigate before continuing"
identifier = records[0]["id"]
assert re.fullmatch(r"iso-[0-9a-f]{8}-[0-9a-f]{16}", identifier), identifier
print(identifier)
PY
)"
"$iso_runtime_bin" inspect --root "$iso_fixture_runtime" "$iso_fixture_id" \
  > "$iso_fixture_root/evidence/native-inspect.json"
"$iso_runtime_bin" exec --root "$iso_fixture_runtime" --timeout 10 "$iso_fixture_id" \
  -- /bin/cat /etc/ssh/ssh_host_ed25519_key.pub \
  > "$iso_fixture_root/evidence/guest-host-key.pub"
```

`iso-sandbox list` returns an array of `{id,status,owner}`. `inspect` returns `{record,status,live,effective,disk}`; a running observation must include effective configuration and a live boot ID. Native `exec` is an argv request over the runtime control channel. Do not use native create/start to bypass the `iso` isolation gate. Sources: [list, inspect and exec contracts](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/iso-sandbox/Sources/IsoSandbox/CLI.swift#L198-L243), [inspect output type](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/iso-sandbox/Sources/IsoSandboxCore/Sandboxes.swift#L20-L26).

**Pass:** machine output reports a running dedicated instance; sentinel matches; runtime record owner/id match fixture records; the worker's normal `iso` path has run its isolation gate; guest host key obtained through native control matches the per-instance pin. Preserve hashes/fingerprints, not private key material. `inspect` by itself may return a missing effective configuration and is not equivalent to the `iso` gate. The gate/native-key/pinned-SSH order is existing behavior: [instance handoff sequence](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/docs/backends.md#L125-L144).

Stop, restart, and later remove only the named fixture:

```bash
"$iso_bin" stop remote-qa --config "$iso_fixture_root/config.json" --output json
"$iso_bin" start remote-qa --config "$iso_fixture_root/config.json" \
  --no-agents --no-github --no-prompt --no-devcontainer --output json
"$iso_bin" exec remote-qa --config "$iso_fixture_root/config.json" \
  -- /bin/cat /workspace/sentinel.txt
```

**Pass:** new boot ID after restart, same intended disk contents, and the same pinned guest host key unless an explicit disk-identity replacement was performed. No snapshot migration is involved.

## 5. Baseline: login state and independent TTL gates

Run setup and the named-instance lifecycle in every applicable row. Use a new root when testing cold setup; retaining a prior image tests only warm start. A supported production product may document an enrollment/provisioning requirement, but its tested requirement must be explicit.

| Stage | Required experiment | Pass evidence |
|---|---|---|
| Dedicated account before any GUI login | Probe, builder preparation, cold image setup, boot, guest command, stop | Operator timeline and observed user/GUI domains; no interaction needed after documented provisioning |
| GUI logged in | Same baseline | Working control case with versions identical |
| GUI locked | Boot a stopped fixture and verify an already-running fixture remains inspectable | Actual control response and guest command; a loaded launchd job alone is insufficient |
| After that account logs out | Repeat boot/inspect/guest command and builder readiness | Continued or explicitly recovered user-domain supervision; no silent dependency on the logged-out session |
| After deliberate worker reboot, before GUI login | Repeat probe, inspect persisted records, then explicitly start fixture; repeat cold setup in a new root | New worker boot-session UUID; retained identity/state; explicit start works; no invented automatic restart claim |

The baseline launches owner jobs in `user/<uid>` with Background session type, `RunAtLoad`, and abnormal-exit restart. It explicitly demands startup with `kickstart` without `-k`. Its plist lives under runtime state, not in `~/Library/LaunchAgents`. Those facts support testing locked-session recovery; they do not establish automatic service start after reboot. Sources: [launchd implementation](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/iso-sandbox/Sources/IsoSandboxCore/Launchd.swift#L3-L36), [existing locked-GUI evidence](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/docs/testing.md#L1002-L1024).

### TTL while client is offline

The fixture's 10-minute TTL is an existing `limits.session_ttl` setting. Begin a fresh boot, immediately capture native inspect with `record.expiresAt`, `live.bootId`, and worker time, then close every client process/SSH connection for this experiment. Keep the worker awake. Do not run stop, destroy, a lease-expiry reconciler, or an administrative shutdown during the interval.

Reconnect close to the recorded deadline plus 120 seconds, inspect through the native read-only command before any `iso start`, and collect the fixture's owner log. Require timestamped host-side expiry/halt evidence, no live owner or VM, and no automatic boot beyond that deadline. The observer must distinguish its reconnect time from the actual host halt time; if the halt time cannot be established, record the deadline bound as unproven. An independently scheduled worker observer can supply additional timestamps, provided it performs observation only and has a lifetime independent of the client.

**Pass:** VM stopped by recorded deadline +120 seconds on an awake worker with an unmodified host clock; disk retained; explicit restart starts a new boot/deadline; the original deadline was enforced without client polling. This is a proposed measurement budget, allowing the existing at-most-30-second clock recheck, 60-second graceful halt, 10-second kill grace, and measurement margin. It is not a claimed existing SLA. Sources: [owner expiry and local timer](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/iso-sandbox/Sources/IsoSandboxCore/Owner.swift#L33-L91), [forced owner exit](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/iso-sandbox/Sources/IsoSandboxCore/Owner.swift#L334-L353), [TTL setting bounds](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/docs/configuration.md#L666-L678).

Separately test worker sleep across the deadline and wall-clock changes; measure reconciliation after wake. Do not claim a running watchdog executes while its host is asleep.

## 6. Candidate: real remote-control spike

**Not implemented by the supplied Python prototype or baseline `iso`.** Implement the thin Swift host-control slice described in the main spec before running this stage. It should call the existing Apple lifecycle and isolation logic on the worker, persist operation outcomes there, and place guest transport behind the worker-owned access-session relay. The default data path remains the dedicated fixture.

Proposed CLI acceptance examples, to be enabled by that implementation:

```bash
# CANDIDATE ONLY: these flags/commands do not exist in the source baseline.
iso host add mac-qa --ssh iso-qa-worker
iso --host mac-qa setup --image remote-qa-base
iso --host mac-qa up ./synthetic-project --name remote-qa --image remote-qa-base
iso --host mac-qa status remote-qa --output json
iso --host mac-qa exec remote-qa -- /bin/cat /workspace/sentinel.txt
```

The harness must enroll with the dedicated client registry and worker fixture root defined by the candidate, rather than the user's default registry. Omitted fixture/config options above are intentionally not guesses at an implemented API: take their exact syntax from the candidate's checked help and record it before running.

The real spike is successful only if all of the following gates pass:

| Gate | Experiment | Required result |
|---|---|---|
| Actual worker invocation | Run hello, image setup, create, inspect, stop, destroy through fixed SSH stdio host control | Version/host identity negotiated; native Apple work occurs only on the selected worker; local paths are not reinterpreted remotely |
| Client-to-guest route | Obtain guest access; exercise shell, file transfer and a development forward through the selected worker relay | Separate management/guest pins; guest address need not be publicly routable; no agent forwarding; every connection records its target host/session |
| Committed create response loss | Test-only fault closes the control frontend after durable create commit but before its response; reconnect with the same operation ID | Exactly one real runtime VM/disk, original identity and outcome returned; changed payload under the ID rejected |
| Access grant response loss and replay (A27) | Drop an `access.open` reply; retry the same SessionID, identity, key, client-generated bearer and expected daemon epoch; then restart the supervisor and replay the old request | The original valid epoch returns matching nonsecret metadata without another grant; changed inputs conflict; a new epoch returns `SESSION_EXPIRED` before grant creation. At the 65,536-issued-ID cap, new opens fail without evicting closed IDs or blocking renewal/close |
| Accepted work survives frontend loss | Drop SSH while create/start is in progress; terminate only the frontend, not the worker operation supervisor | Operation either completes once or retains an explicit recoverable outcome; the client never reports stopped from a transport error |
| Start response loss | Drop response after accepted start; retry same operation ID | Same boot and original deadline; no second start and no TTL extension |
| Duplicate receipt after changed admission (A28) | Retry a recorded operation after runtime qualification or its input artifact availability changes | Matching durable receipt/reconciliation remains available before new-work admission checks; no replacement resource allocation |
| Quota-full safety cleanup (A29) | Exhaust the ordinary operation-ledger quota in the dedicated candidate fixture, then request new resource work and exact owned stop/destroy; expire a live session | New resource work is refused; reserved cleanup capacity still permits native stop, exact destroy and safety revocation. Retained-resource acknowledgment/discard remain available |
| Unreachable worker | Cut only the client's management path, then request status/retry | Client reports unknown/unreachable with last-observed time; no implicit create, restart, or successful deletion |
| Two hosts, equal local values | Run one project locally and remotely, deliberately matching instance names/private IPs/indexes where possible | Distinct host-qualified IDs, keys, tunnels and aliases; broker ports are reserved in the client namespace and cannot collide |
| Management identity changes | Present a changed worker SSH key or different enrolled host ID | Fail before VM mutation; explicit re-enrollment required |
| Boot and policy change | Keep an old access handle, restart the fixture or change its policy generation, and attempt new/renewed access | Old handle rejected; fresh proof required; no capability silently rebound to replacement boot |
| Active session expiry | Hold an interactive shell, editor tunnel and development forward open; stop renewals while worker stays up | Worker closes established relay connections by the specified lease deadline/grace and denies new access; removing only an authorized key is insufficient |
| Broker disconnect | Run client-broker mode using a dedicated test broker, then disconnect client | New required broker work fails closed; supervised attached jobs/sessions end according to the lease; no automatic credential migration |
| Disposal after client loss (A18) | Run a dedicated disposable workload; disconnect before command completion is reported | Worker stops the VM first. After verified stop, expose `results_pending` only for a complete committed artifact, otherwise `stopped_disk_pending_export`; retain the exact disk. Do not invent command completion or delivery. Delete only after acknowledgment, explicit discard, or retention expiry, and report destroyed only after verified absence |
| Recovery export and fixed retention (A30) | Preempt an export with lease/TTL expiry, then explicitly request `run.results.recover`; lose its reply and retry; attempt a second recovery | Partial bytes never become a result. At most one recovery boot occurs under recorded child IDs, fresh proof, denied general egress/client-service access, and TTL at most five minutes and no later than the original retention deadline. The service does not relaunch the user command, agent, hooks or installers. Stop and verify afterward; one-hour retention from the first verified stop never moves |
| Result acknowledgment and expiry race (A34) | Fsync a complete client stage, acknowledge its exact digest/StageID, drop the reply and retry the same operation; separately race a download against retention expiry | Durable acknowledgment reconciles once; no fabricated delivery and no reuse of a deleted VM. Expiry stops any recovery boot and deletes exact owned resources; an uncertain stop/delete remains explicit. A completed client stage survives worker cleanup |
| Staged return | Stage guest changes on client, disconnect worker, inspect the stage | Completed stage remains reviewable; destination stays the client-selected path and records origin host |
| Migration prepared/activation handoff (A32) | At a stopped boundary, fault the candidate migrator before `prepared`, after each fence/metadata step, after releasing its locks, and before/after supervisor `active` commit | Before `prepared`, recover metadata under locks; afterward every supervisor start is activation-only until recovery completes. The migrator releases service/mutation locks before the supervisor acquires them. No deadlock, ordinary dispatch before `active`, half-active root or automatic VM stop; success requires committed `active` and matching hello identity |
| Activated local adapters (A31) | On a separately owned migration fixture, exercise existing resize/commit/restore and a prepared local macOS guest after activation | Actions traverse the host service while retaining native journals and current user semantics; unsupported SSH actions refuse before image/secret work |
| Cancellation dispatch race (A33) | Race a request cancellation against dispatch using a candidate-only synchronization hook | Exactly one wins under the mutation lock; cancelled-before-dispatch has no external effect; cancellation after dispatch produces the specified typed refusal |

Current runtime create/start do not accept the `--operation` flag used by set/grow/restore. The spike must implement durable create/start deduplication in the host service and reconcile underlying runtime identity; it cannot assume the existing runtime already supplies these semantics. Source: [create/start arguments and existing operation scope](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/iso-sandbox/Sources/IsoSandbox/CLI.swift#L115-L165), [operation options](https://github.com/chr33s/iso/blob/47d17ba2524b145b229abcf42c85f8b5f0071e65/iso-sandbox/Sources/IsoSandbox/CLI.swift#L246-L252).

A direct ProxyJump connectivity experiment can diagnose reachability, but it cannot pass the worker-enforced session-revocation gate. The worker-owned relay/supervisor must demonstrate control of established connections, including long-lived forwards. Provider credentials are unnecessary for the lifecycle/routing spike; use a synthetic test broker before a separately scoped real-provider smoke test.

These added candidate experiments are **unimplemented and not run** by this deliverable; the simulated Python session model does not validate real client bearers, daemon epochs, relays, result export, quotas, or migration locks. Use the authoritative transitions in main-spec sections 9, 12 and 14. For migration, include a control case with a legacy VM still running or an old writer alive: activation must defer with exact blockers, preserve the running VM, and retain compatible inspection/stop/file-return access. A fresh remote fixture may operate while the client's local migration remains pending.

## 7. Cleanup and go/no-go decision

After capturing evidence, use the exact fixture name and its exact config:

```bash
"$iso_bin" stop remote-qa --config "$iso_fixture_root/config.json" --output json
"$iso_bin" destroy remote-qa --config "$iso_fixture_root/config.json" --output json
"$iso_runtime_bin" list --root "$iso_fixture_runtime"
```

Require the dedicated runtime list to be empty and reconcile all operation handles. Retain image/evidence files for review; this runbook performs no broad cleanup or deletion of the fixture directory. The candidate's cleanup must likewise use host-qualified immutable IDs and query the same worker on uncertain outcomes.

**Proceed with implementation rollout only after:** baseline cold/warm and login-state evidence is recorded; the real remote slice passes operation-loss, identity, relay-revocation and TTL gates; local behavior remains compatible; and blocked filtered-egress qualifications are resolved for any capability the release advertises. A passed simulated protocol suite supports the design but leaves these gates open.

If SSH-only image building fails while an already-built image can run, record those as separate capabilities. A workable product may require a documented image-preparation step, but it must not claim unattended cold provisioning until demonstrated. If the user-domain worker cannot meet the intended logout/reboot lifetime, investigate a managed service installation as a deliberate design change with its own permissions and evidence rather than weakening the live checks.
