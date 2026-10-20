# iso-ci — Qualification record

**Document ID:** ISO-CI-QUAL  
**Date:** 20 October 2026  
**Status:** Evidence record for the [iso-ci specification](iso-ci-specification.md) (ISO-CI). No case below is a release sign-off. Release qualification of a signed, tagged build has not been recorded.

This record holds the evidence gathered against the specification's
acceptance tests (section 14) and the defects that evidence exposed. The
specification keeps the contract, where each part lives, and the open gaps.
The operator guide is [`docs/ci.md`](../ci.md).

Local preflight and a GitHub-connected repository pool have both run end to
end against real GitHub and the official runner on qualified brokered Macs:
the development Mac, and a second Mac (`mba`) as a worker of the same pool. An
organization pool also ran against a GitHub organization.

## Test environments

**Development Mac.** One Apple Silicon Mac on macOS 27, using the release
bundle and a dedicated iso config (brokered, filtered egress). NET-HANDOFF-1
evidence was recorded for the `ci-runner` image (manifest digest bound to
`ci-runner@sha256:63d8616d…`), and the host advertised `net-handoff-1` with
that `qualified_image`. Every live run used fresh brokered VMs running the
official runner v2.338.0 and ended with verified VM destruction (no instances
or cleanup debt left).

**Repository pool.** The development Mac served a `validation` pool for a
private repository through a GitHub App owned by a personal account (created
with the manifest flow, installed on that one repository). Every job ran on a
fresh brokered VM with a fresh JIT registration, and every allocation ended
with its registration removed and VM destruction verified.

**Organization pool.** An App owned by the `iso-ci` organization (Self-hosted
runners write, Actions read, Metadata read), installed on it, served an
organization pool in runner group `Default` on the development Mac.

**Preflight containers.** The development Mac with a registry-only filtered
preflight policy (`ghcr.io`, `pkg-containers.githubusercontent.com`).

**Second worker (`mba`).** macOS 27.0.1, Apple Silicon, no Xcode. It received
the release bundle and ran the brokered suite from that bundle
(`ISO_TEST_PREBUILT`):

| Run | Result |
|---|---|
| `setup`, `brokered`, `iso` phases | 185 passed, 1 skipped (Touch ID) |
| `brokered` phase rerun | 47/47 |
| N-T05 | 5/5 |
| N-T08 (`--brokered --prebuilt`) | pass |
| `ci-runner` image checks | 19/19 |

The one failure in the first full run was N-T02's LAN positive control. A
Homebrew Python that the macOS firewall did not allow had run the canary; with
the system Python the rerun passed. `mba` then recorded its own NET-HANDOFF-1
evidence for its own image build.

## Fixture-level checks

These ran on the development Mac. They are local, fixture-level checks, not
acceptance-test qualification:

- `swift test --package-path iso-ci`: 173 tests, including the regression
  fixtures named in section 14 (unassigned warm allocation, lost JIT
  response, `validation` label not withholding secrets, shared cache allowed
  versus private object denied, source mutation after overlay,
  unavailable-worker cleanup debt) and retained-secret handling (secrets
  never persisted).
- `iso-ci/scripts/test-dataplane-jail.sh` against the built executable: the
  confined child cannot read a controller-private file, write outside
  staging, create symlinks or hard links, open TCP or execute a process;
  its staging directory stays writable.
- `DataPlaneConfinedTests` (opt-in, `ISO_CI_E2E_BINARY`): the production
  supervisor runs the self-test, launches the real confined child, which
  binds one socket per allocation, refuses an unauthenticated request and
  removes the socket on unregister.
- Root package: the host tests for `host.capabilities`, `run.retain` and the
  client bridge, and 18 fault-injection cases that the tests detect.

## Live acceptance cases

Scope is the environment above: **preflight** (local preflight on the
development Mac), **repository** (repository pool), **organization**
(organization pool) or **two-worker** (development Mac and `mba`).

| Case | Scope | Live observation |
|---|---|---|
| C-T01 | Preflight | Before evidence was recorded, a submitted job failed `CAPABILITY_MISSING` with no VM created. After evidence was recorded, the next controller pass refreshed the host snapshot and the retried job ran. |
| C-T02 | — | No separate live entry recorded. |
| C-T03 | Repository | Two smoke jobs ran on different runner names and VMs (checked by the smoke verifier). A later five-job run used five runners and five VMs. The App held only `administration:write`, `actions:read` and `metadata:read`, and the guarantees GitHub could not verify (fork approval, secret withholding) were reported as unavailable, not assumed. |
| C-T03 | Organization | The guarantees verified the installation, the permissions and the group (visibility all, public repositories refused); workflow restriction and secret withholding were reported unavailable. Two jobs ran on separate organization runners and VMs. `pool remove` released the pool's idle runner and reached `removed`. |
| C-T04 | Repository | Inside a job: no private-key material in the environment, and none on disk outside the work tree except the VM's own SSH host keys. The JIT configuration reached the guest on stdin only. |
| C-T05 | Repository | `actions/checkout`, `actions/cache` (save in one VM, restore in another), `upload-artifact`/`download-artifact` across jobs, an Alpine job container with an nginx service container reached by name, and HTTPS to an approved host from inside a job container. |
| C-T05 | Preflight | A preflight workflow passed with an Alpine job container and an nginx service container reached by name, a `docker://` container action, `actions/upload-artifact` running inside a job container, and a dependent job that downloaded that artifact. The overlay step applied and verified the snapshot inside the Alpine container. |
| C-T06 | Repository | A host LAN canary listener recorded no connection from any job. From the job and from a host-network Docker container, the LAN canary, the host's tailnet address, the metadata address, a raw public IP and an unapproved host were all unreachable. The positive control, an approved host, was reachable from the guest and from a job container. |
| C-T07 | Repository | A job cancelled in GitHub and a job that hit `timeout-minutes` both ended with GitHub's `cancelled` conclusion recorded separately from the runner's exit, the registration removed and VM cleanup verified. |
| C-T08 | Repository | The controller was killed with SIGKILL while an allocation's VM was ready and its registration `intended`. After a restart it resumed the same allocation and VM, created exactly one runner with the allocation's own name, and the host counted one live VM with nothing uncertain. |
| C-T09 | Preflight | `runs-on: macos-latest` plus a cross-repository reusable workflow were refused at submit (`COMPATIBILITY_REJECTED`); no allocation. |
| C-T10 | Preflight | Inside the job after the synthetic checkout and overlay: modified content, a deletion, an executable-mode change and an explicitly `--include`d untracked file were present; a non-included untracked file was absent. Every report says a dirty snapshot is not evidence for the base commit. |
| C-T11 | Preflight | A two-job workflow passed a `needs` output, uploaded and downloaded an artifact, and saved a cache that the second VM restored (`cache-hit=true`). In another run, the same artifact name was not found. From a job step, the service endpoint answered 401 to unauthenticated and forged-token requests to the artifact, cache and snapshot routes. |
| C-T12 | Preflight | A traversal path got 403, and a 64 MiB request body got 413. |
| C-T13 | Preflight | A failed job was retained live for a finite window and counted against the budget. `iso-ci debug` opened a session into it. `iso-ci patch --from-working-tree` recorded input revision 1 and applied it to the retained workspace. `iso-ci retry --from-start` ran attempt 2 in a fresh VM on revision 1 and succeeded. Attempt 1 keeps its failure and its patch revision. `abort` released the retained VM. |
| C-T14 | Two-worker | One pool on `local` and `qmba` ran an eight-job matrix, five jobs here and three on `mba`. Each ran in its own VM (eight boot ids) under its own runner, with at most three live allocations (`max_live_vms`). Mid-run the controller was restarted and the pool drained with jobs queued: assigned work finished, no runner was registered while draining, and `pool resume` continued the run. Every allocation ended with VM cleanup verified. |
| C-T15 | Repository | A `privileged` pool stayed inactive ("privileged release execution is not qualified") even after an explicit `pool resume`. A job aimed at its labels stayed queued for 90 s with no runner and no allocation, while the validation pool's idle runner, which has other labels, stayed idle. A second pool with the validation pool's scope and labels made both inactive within one pass, and the validation pool's idle runner was retired. |
| C-T15 | Organization | Public trigger: with the organization pool active and a runner idle, the operator ticked "Allow public repositories" on its runner group. Within 10 s the pool went inactive ("runner group Default allows public repositories; public execution is not qualified"). Within about 50 s its idle runner's registration was removed and its VM cleanup verified. Unticking the setting reactivated the pool. |
| C-T16 | Repository | A six-job matrix with `max_live_vms: 2` never exceeded two live allocations; the queued jobs waited on GitHub and all succeeded on separate runners. A job that filled its VM's 64 GiB disk was bounded by the job timeout, its VM was destroyed with cleanup verified, and the host's free space was unchanged. |
| C-T17 | Repository | `pool remove` deleted the only registered runner (GitHub then listed none), released its VM with cleanup verified, left no instances under the qualification config and kept the App credentials (`--remove-credentials` was not given). |
| C-T18 | Repository | With the approved runner version set to 2.337.0 against the image's 2.338.0, the pool booted a VM, read the version, drained ("runner version 2.338.0 differs from the approved 2.337.0") and released the VM; no runner was registered with GitHub. Restoring the version reactivated the pool. |

## Coverage limits

- Custom runner groups with workflow restrictions need a paid GitHub plan and
  were not exercised; the free organization's `Default` group was.
- Public and fork execution, and privileged release execution, are qualified
  by refusal, as specification section 10 requires until enforceable controls
  exist. GitHub does not let the installation verify fork-approval or per-job
  admission. So a pool whose repository is public, or whose runner group
  admits public repositories, stays inactive, and a `privileged` pool stays
  inactive even after `pool resume` (both seen live, C-T15). A release must
  list both as deliberately unsupported capabilities (specification
  section 15).

## Defects found and fixed

### Preflight runs

The live preflight runs on the development Mac exposed and fixed five
defects:

- The controller never refreshed host capability snapshots after `enable`. It
  now refreshes them every 60 s and records changes as events.
- A late launch error could overwrite a job result already recorded.
- A retry did not re-queue downstream jobs that had been skipped.
- Any `--include` captured every untracked file.
- `run --follow` exited 0 for a failed run.

### Connected pools

The repository and organization pool runs exposed and fixed these defects:

- **Keychain storage:**
  - The data-protection keychain needs an entitlement an unsigned build lacks,
    so the App key now goes to the login keychain.
  - Access to it is tied to the executable that stored it, so a rebuilt
    `iso-ci` must store the key again (`setup` says so).
  - A failed key store after the App was created now names the App and the
    recovery steps instead of leaving an orphaned App.
- **Proxy authentication (base iso):** the official runner's .NET client sends
  proxy credentials only after a `407` challenge. iso-egress now answers a
  missing or wrong capability with a `407` Basic challenge
  ([configuration](../configuration.md)).
- **Sharded service hosts:** GitHub assigns `pipelines`, `run-actions-N` and
  results-storage hosts per account and per job.
  - Base iso's filtered egress now accepts reviewed `*.<suffix>` rules
    ([configuration](../configuration.md)).
  - Before starting a runner, the controller checks the service hosts in its
    JIT configuration against the approved policy and pauses the pool if any
    is not covered.
- **Controller hangs:**
  - A hung subprocess could stall the controller: a descendant that left its
    process group kept the output pipes open, and the subprocess wait now
    returns anyway.
  - The SSH relay now ends after stdin EOF when the guest side stays open.
- **Pause during a pass:** a pool paused partway through a reconcile pass
  still created replacement runners. The pass now re-reads the pool state
  before replenishing.
- **Docker containers had no egress:** the runner bootstrap handed job,
  service and action containers the guest-loopback proxy address, which is
  unreachable from inside a container. It now gives them the guest's bridge to
  the egress companion on Docker's gateway.
- **Container step permissions:** the bootstrap's `umask 077` was inherited by
  the runner, so containers running as another user could not read their step
  scripts. The runner now starts with `umask 022`.
- **Execution outcome:**
  - A runner that exited cleanly with no observed job was recorded as
    `succeeded`; it is now `unknown`.
  - A job that started and finished between two passes is now bound from
    GitHub's newest completed runs by exact runner identity.
- **Export outcome:** completing a run that never requested results recorded
  `export: failed`; it now stays `not_requested`.
- **Stale activation:** a cached activation ignored configuration edits for up
  to 600 s. It is now keyed by the pool's descriptors and every pool's
  routing.
- **Inactive pools kept idle runners:** an inactive pool kept its idle runners
  registered, so GitHub could still assign them jobs. Those runners are now
  retired.
- **GitHub-side re-check interval:** GitHub-side controls were re-read every
  600 s, so a runner group that started admitting public repositories left the
  pool active for up to 10 minutes. They are now re-read every 60 s, and a
  pool that turns inactive retires its idle runners.
- **Installation verification scope:** `setup` checked an installation
  against every configured pool's scope, so an organization App would have
  been asked for a repository pool's Administration permission. It now checks
  only the pools that use that installation.

### Two workers

The two-worker run exposed and fixed these defects:

- **Per-host image builds:** each Mac builds the runner image from its own
  build context, so one image digest cannot serve two workers. An image
  descriptor now takes approved `host_digests`, and admission and
  `run.create` use the chosen host's digest.
- **Agent-held SSH keys:** iso's management SSH to an enrolled host dropped
  the SSH agent, so a host whose key lives only in the agent (a passphrase via
  the agent, 1Password, Secretive) was unreachable. It now keeps
  `SSH_AUTH_SOCK` for that connection only; guest SSH still refuses the agent.
  Two new fault-injection cases cover this.
- **One host blocking the pool:** a host that refused admission stopped
  replenishment for the whole pool. Placement now skips it for the rest of the
  pass and uses the next host.
- **Interrupted provisioning:** an allocation whose provisioning was
  interrupted by a controller restart, and whose host run had stopped, held
  capacity for twice `boot_seconds`. It is now released on the next pass.

### Preflight containers

Getting the preflight container workflow (C-T05, preflight) to pass exposed
and fixed these defects:

- **Unreadable job logs:** stored runner logs could not be read by any
  command. `iso-ci logs RUN --job JOB [--attempt N]` now prints them, with
  control characters removed.
- **Unreachable endpoint:** containers could not reach the endpoint on the
  guest's loopback. With Docker, it is now also served on Docker's gateway
  through a guest-internal bridge, and every URL the job sees names that
  address. The launch fails fast (a distinct status) if the bridge is not
  reachable.
- **Proxied endpoint traffic:** the preflight runner sent its endpoint traffic
  to the egress proxy, which refused it. The runner and its containers now get
  no proxy; Docker's daemon keeps its own for pulls.
- **Synthetic steps:** they required bash, curl and git. They are now POSIX
  `sh`, fetch with curl or wget, and leave no `.git` where git is missing.
- **No acquisition deadline:** a runner that never acquired its job held its
  VM until the hard deadline. It now fails the attempt after the profile's
  `boot_seconds` (seen live: "the runner did not acquire the job within
  600 s"), and the VM is retained for `debug`.

### Simplification review

A later review removed dead code and merged the two runner launchers. Its
live checks found two more defects:

- **Result export was never requested:** nothing could ask for a run's
  results, so the export path was unreachable and `export_grace_seconds` was
  ignored. `iso-ci results ALLOCATION [--save DIR]` now requests them, and
  the profile's stop plus export grace bounds the host's completion.
- **Base iso refused every results archive:** a guest's `tar cf - -C dir .`
  (GNU or BSD) leads with a `./` directory member, which the host's archive
  validator refused as "names the root". Only an empty root directory member
  is now skipped (fault `archive-root-directory-only`). Live, after the fix,
  a preflight job's `~/iso-results/hello.txt` was requested while it ran,
  exported when its VM completed, and saved with `--save`.

The merged launcher was checked live afterwards on both workers: the
five-job acceptance run passed, and so did the preflight container run.

### Review hardening

An independent security and correctness review led to these changes:

- **Host-side image binding:** under NET-HANDOFF-1 the host refuses a run
  whose `image_digest` is not the image's exact manifest digest. The host
  advertises `qualified_image`, and admission requires the profile's image
  name and digest to equal it.
- **Data-plane child:**
  - The controller never resolves paths the child can change: staging is
    reached through directory handles, and the profile denies symlink and
    hard-link creation.
  - Storage is charged by bytes actually committed. Sparse cache uploads and
    repeated block ids are refused.
  - Each allocation gets its own socket, with connection and header
    deadlines, and every credential is bound to that socket.
- **Lifecycle:**
  - Refused host operations get a fresh identity, while uncertain ones keep
    theirs.
  - A sweep owns every preflight allocation until it settles.
  - Late results for ended attempts are ignored, and abort revokes the
    endpoint.
  - Never-registered connected allocations settle.
  - Removed or credential-less pools are still offboarded from the last valid
    configuration.
  - Controller passes are serialized.
- **Live retention:** it revokes access grants only. The boot network policy
  and anything already in the guest remain until the VM stops (documented in
  the [trust model](../trust-model.md)).
