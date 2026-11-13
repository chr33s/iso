# iso-ci: isolated GitHub Actions execution

`iso-ci` is a separately installed companion to iso. It runs GitHub Actions
jobs in clean, NIC-less iso VMs on your own Apple Silicon Macs, in two modes:

| Mode | Who decides what runs | What iso-ci does |
|---|---|---|
| **GitHub-connected pool** | GitHub | Keeps a bounded number of fresh, single-use official runners ready. GitHub assigns jobs, records checks, and keeps its normal caches and artifacts. |
| **Local preflight** | iso-ci | Compiles a workflow from the supported subset, captures your working tree or staged index as an immutable snapshot, and runs each job through the official runner against local services. You can inspect, debug, patch and rerun a job from the start. |

Each job attempt gets its own VM and its own guest-local Docker daemon. iso-ci
never reuses a VM for a second job, never registers or changes a developer
VM, and never falls back to a networked VM. Base iso does not need iso-ci or
any GitHub credentials.

The design and the requirements it implements are in the
[iso-ci specification](design/iso-ci-specification.md). Release qualification
of a signed, tagged build has not been recorded; the evidence gathered so far
is in the [qualification record](design/iso-ci-qualification.md).

## Before you start

On every Mac that will run CI jobs:

1. Install iso and complete `iso setup`
   ([installation](installation.md), [backends](backends.md)).
2. Use the brokered transport. In `~/.iso/config.jsonc`:

   ```jsonc
   {
     "network": { "transport": "brokered" },
     "egress": "filtered",
     "egress_filter": {
       "allowed_hosts": [
         "github.com", "api.github.com", "codeload.github.com",
         "objects.githubusercontent.com", "*.actions.githubusercontent.com",
         // all twenty results-storage accounts, each listed exactly:
         "productionresultssa0.blob.core.windows.net",
         "productionresultssa1.blob.core.windows.net",
         "productionresultssa2.blob.core.windows.net",
         "productionresultssa3.blob.core.windows.net",
         "productionresultssa4.blob.core.windows.net",
         "productionresultssa5.blob.core.windows.net",
         "productionresultssa6.blob.core.windows.net",
         "productionresultssa7.blob.core.windows.net",
         "productionresultssa8.blob.core.windows.net",
         "productionresultssa9.blob.core.windows.net",
         "productionresultssa10.blob.core.windows.net",
         "productionresultssa11.blob.core.windows.net",
         "productionresultssa12.blob.core.windows.net",
         "productionresultssa13.blob.core.windows.net",
         "productionresultssa14.blob.core.windows.net",
         "productionresultssa15.blob.core.windows.net",
         "productionresultssa16.blob.core.windows.net",
         "productionresultssa17.blob.core.windows.net",
         "productionresultssa18.blob.core.windows.net",
         "productionresultssa19.blob.core.windows.net",
         "ghcr.io", "pkg-containers.githubusercontent.com"
       ]
     }
   }
   ```

   GitHub assigns runner service hosts per account and per job under
   `actions.githubusercontent.com` (`pipelines…`, `run-actions-N-<region>…`),
   so that domain is allowed as one reviewed wildcard; job logs and results
   go to GitHub's documented `productionresultssa0`–`19.blob.core.windows.net`
   storage accounts, all twenty listed exactly. Add only the package
   registries your jobs need. iso-ci never adds a host to this list, and a job
   cannot request one.
3. Run the brokered qualification suite and record its evidence
   ([remote hosts](remote-hosts.md#brokered-handoff-evidence)):

   ```sh
   python3 scripts/record-net-handoff-evidence.py --results results.json
   ```

   Until valid, unexpired evidence for the exact host tuple is installed, the
   host does not advertise `net-handoff-1` and iso-ci admits nothing there.
4. Build the runner image from the profile in
   [`iso-ci/images/ci-runner.profile.jsonc`](../iso-ci/images/ci-runner.profile.jsonc).
   Add the `ci-runner` profile to the host's iso configuration, then:

   ```sh
   iso setup --profile ci-runner --image ci-runner
   ```

   The image holds the official Actions runner (pinned version and SHA-256)
   on iso's base image with Docker and the SSH server. It contains no runner
   registration, project state, caches, App material or provider credentials.

To use another Mac, enroll it with iso first
(`iso host add ...`, [remote hosts](remote-hosts.md)). iso-ci uses iso's
enrollment and pinned SSH; it never discovers tailnet nodes, and job VMs never
join a tailnet.

Build and install iso-ci from a repository checkout (it builds the shared
inert Git index reader from the sibling `iso-policy` package):

```sh
swift build -c release --package-path iso-ci
install -m 0755 iso-ci/.build/release/iso-ci ~/.local/bin/iso-ci
```

## Configuration

iso-ci keeps its state under `~/.iso-ci` (or `$ISO_CI_HOME`, or `--root`):
`config.yaml`, the controller database, an object store, private session files
and logs. `iso-ci setup` writes a starting `config.yaml` for review.

The configuration is administrator-controlled. Workflows can name a pool's
labels; they can never define host executables, secrets, network
destinations, privileges or resource ceilings.

```yaml
schema: iso-ci/v2     # iso-ci/v1 files stay valid; `schema_version: 2` also works

images:              # approved runner images on iso hosts
  approved-linux-arm64-runner:
    iso_image: ci-runner
    digest: sha256:...       # the image the host's NET-HANDOFF-1 evidence names
    runner_version: 2.338.0
    docker: true

network_policies:    # what a job VM may reach, through iso's brokers only
  approved-ci-public-egress:
    egress: filtered
    required_hosts: [github.com, api.github.com, ...]
  approved-preflight-egress-and-service:
    egress: none
    preflight_service: true

compatibility:
  approved-connected-linux: { mode: connected }
  approved-local-actions: { mode: preflight, manifest: local-actions/v1 }

limits:              # every value is required and finite
  operator-approved-ci-limits:
    cpus: 4
    memory_mib: 8192
    disk_gib: 64
    boot_seconds: 600
    idle_seconds: 3600
    job_seconds: 21600
    hard_deadline_seconds: 28800
    stop_grace_seconds: 60
    export_grace_seconds: 300
    output_bytes: 67108864
    log_bytes: 67108864
    traffic_bytes: 4294967296
    live_retention_seconds: 3600
    stopped_retention_seconds: 86400

hosts:               # controller-side budgets; each host still admits on its own
  local: { max_vms: 2, cpus: 8, memory_mib: 16384, disk_gib: 256 }

profiles:
  linux-validation:
    platform: linux/arm64
    image: approved-linux-arm64-runner
    network_policy: approved-ci-public-egress
    compatibility: approved-connected-linux
    authority: validation
    limits: operator-approved-ci-limits

pools:
  validation:
    profile: linux-validation
    hosts: [local]
    github:
      installation: selected-installation
      scope:
        repository: OWNER/REPOSITORY
      labels: [self-hosted, linux, ARM64, iso-ci]
    max_live_vms: 2
    desired_idle_vms: 1
    retention_on_failure: disabled

preflight:
  profile: linux-preflight
  hosts: [local]
  architecture_mapping: explicit
  retry: fresh-job
  platform_map:
    ubuntu-latest: linux/arm64
  max_parallel_jobs: 2
```

Rules the controller enforces:

- The image `digest` is required and must equal the image named in the host's
  qualification evidence (`iso-ci status` shows it as `qualified_image`); any
  other image is refused as unqualified. Each Mac builds the runner image from
  its own build context, so the same profile has a different digest on each
  host. For a pool on several hosts, list the other hosts' qualified digests
  under `host_digests: {ALIAS: sha256:...}`. They are part of the approved
  descriptor, and a host's VMs boot exactly its listed digest.
- Every host a pool or `preflight` lists needs its own `hosts:` budget.
- `platform` is `linux/arm64`. There is no implicit architecture translation.
  Preflight accepts exactly `[self-hosted, linux, ARM64]` (case-insensitive,
  optionally with labels that `platform_map` maps to `linux/arm64`) without
  any `platform_map` entry; every other `runs-on` must map entirely through
  `platform_map` to `linux/arm64`.
- `egress` is `none` or `filtered`, never `open`. `required_hosts` are exact
  hostnames or iso's `*.<suffix>` rules ([filtered
  egress](configuration.md#egress)). Each must be covered by the host's
  approved allowlist: an exact name by itself or a host wildcard above it, a
  wildcard only by the same wildcard. Before a connected runner starts, the
  controller reads the service hosts in GitHub's JIT configuration and pauses
  the pool, naming them, if the approved policy does not cover them.
- With filtered egress, a connected runner's proxy is the guest's bridge to
  the egress companion on Docker's default gateway (`172.17.0.1`), and the
  runner passes it to job, service and action containers. A job that reaches
  a service container by name must list that name in `no_proxy` (for example
  `env: {no_proxy: "web,localhost,127.0.0.1"}`); the companion only relays
  approved hosts on port 443. Clients that ignore `no_proxy` (busybox `wget`)
  need their own proxy switch.
- Every descriptor has a digest. A pool activates only when each descriptor it
  uses matches the digest you approved (`iso-ci setup --approve`); a later
  edit leaves the pool inactive until you approve again.
- `authority: privileged` pools stay inactive: privileged release execution is
  not qualified.
- For an organization pool, replace `repository:` with
  `organization: ORG` and `runner_group: GROUP`, and give it its own
  `installation:` name. A private GitHub App can be installed only on the
  account that owns it, so create the organization's App with
  `iso-ci setup --create-app --app-organization ORG`, install it there, then
  run `iso-ci setup --find-installation --app-id ID --repository ORG/REPO
  --installation-name NAME`.
- An invalid or partial configuration leaves the affected pools inactive.

### Scale sets and shared hosts

A pool's `provisioning_mode` is `warm_pool` (the default: keep
`desired_idle_vms` runners registered ahead of demand) or `scaleset`. A
scale-set pool registers a GitHub runner scale set named `scaleset.name`,
holds a long-poll message session with GitHub's Actions service, and starts
a VM only for a job GitHub gives it that passes the pool's `job_policy`. With
`min_runners: 0` an idle pool holds no VM and no registration. Workflows
target it with `runs-on: <scaleset.name>` (or its labels). The App needs the
usual runner permissions (Administration write for a repository pool, Self-hosted
runners write for an organization pool).

```yaml
hosts:
  local:
    max_vms: 4
    cpus: 12                       # the Mac's ceiling for iso and iso-ci together
    memory_mib: 32768
    disk_gib: 512
    owner_reserved_cpus: 2         # never admitted to CI
    owner_reserved_memory_mib: 4096
    track_external_macos_vms: true # local host only

profiles:
  linux-heavy-bench:
    # ...as above...
    exclusive_host: true           # drain the host first and run alone

pools:
  iso-main-scaleset:
    profile: linux-validation
    hosts: [local]
    github:
      installation: selected-installation
      scope: { repository: OWNER/REPOSITORY }
      labels: [self-hosted, linux, ARM64, iso-arm64-fast]
    provisioning_mode: scaleset
    scaleset:
      name: iso-arm64-fast
      min_runners: 0
      max_runners: 4
      job_policy:
        allow_fork_prs: false      # the default
        allow_public_repo: false   # the default
        allowed_events: [push, pull_request, workflow_dispatch, merge_group]
        allowed_actors: []         # empty: any actor under allowed_events
    retention_on_failure: disabled
```

- A scale-set pool takes `scaleset.min_runners` and `max_runners` instead of
  `desired_idle_vms` and `max_live_vms`. Each job still gets one fresh,
  single-use VM and a JIT runner registered in the scale set.
- iso-ci creates the scale set *elastic* when GitHub allows it, else
  *non-elastic*; the `scaleset.created` event says which. Creating an elastic
  scale set needs Administer permission, which an App installation does not
  hold, so an App gets a non-elastic one.
  - **Elastic:** GitHub offers each job, and iso-ci checks the policy before
    acquiring it. A refused job never reaches the scale set and stays queued
    for other runners.
  - **Non-elastic:** GitHub assigns jobs to the scale set directly, and any of
    its runners may take any assigned job. iso-ci checks each job as it is
    assigned. While any assigned job is refused, or was assigned before this
    session began (after a restart), iso-ci starts **no** runner for that
    scale set (`iso-ci status` says why). A refused job keeps blocking the pool
    until it leaves the queue (cancel it, or GitHub expires it). A runner
    already started for an approved job can still take a refused job assigned
    while it boots; public repositories therefore need an elastic scale set.
    An idle runner could take a job before it is vetted, so a non-elastic
    scale set needs `min_runners: 0` (the listener refuses to run otherwise).
- The policy is decided on GitHub's own workflow run record (`GET
  /repos/{owner}/{repo}/actions/runs/{id}`), never on the job message alone.
  On an elastic scale set a refused job never gets a registration, a host
  admission or a VM (see the non-elastic race above). Each
  refusal is an event with its code:
  `JOB_REJECTED_PUBLIC_REPO`, `JOB_REJECTED_FORK_PR` (the run's head is
  another repository, or a pull request run names none), `JOB_REJECTED_EVENT`,
  `JOB_REJECTED_ACTOR` (the actor or re-run's triggering actor),
  `JOB_REJECTED_SCOPE` and `JOB_REJECTED_UNVERIFIABLE` (unreadable, or the
  run disagrees with the offer).
- `allow_public_repo: true` needs `min_runners: 0` and an elastic scale set
  (the listener refuses to run otherwise), cannot be combined with
  `allow_fork_prs: true`, and
  allows only events that need write access to trigger (`push`,
  `pull_request`, `workflow_dispatch`, `merge_group`, `schedule`) unless
  `allowed_actors` names who may trigger. Only scale-set pools can opt in:
  a warm pool on a public repository, or on a runner group that admits public
  repositories, stays inactive.
- Every pending unit of work, across all pools (scale-set jobs and missing
  warm runners), waits in one queue ordered by age. The oldest job that
  waits only for capacity on a host reserves room there: later jobs may use
  that host only if the reserved job would still fit beside them, so small
  jobs cannot starve a large one.
- A job for an `exclusive_host` profile drains its host: idle runners there
  are retired, nothing else is placed, and it starts once the host has no CI
  VM. Normal placement resumes when it exits.
- CI's ceiling on a host is `cpus`/`memory_mib` less the owner reservation
  and the CPU and memory of VMs iso-ci does not own. On the `local` host
  these are read from the leases that iso-sandbox writes for every running VM
  (`~/.iso/run/leases/<sandbox>.json`, held under `flock` while the VM runs).
  Virtualization.framework runs at most two macOS VMs per Mac; a macOS job
  waits as `QUEUED_WAITING_VZ_SLOT` while two run. With
  `track_external_macos_vms: true`, VM processes that hold no lease also count
  as macOS VMs. CI profiles can name `platform: macos/arm64`, but such a pool
  stays inactive: macOS guests need a network interface, and CI runs only
  NIC-less (NET-HANDOFF-1) guests.
- The new profile and pool fields are part of their descriptor digests, so
  setting them needs `iso-ci setup --approve`; descriptors that do not use
  them keep their digests. A host budget that sets `owner_reserved_cpus`,
  `owner_reserved_memory_mib` or `track_external_macos_vms` becomes an
  approved descriptor too: pools and preflight on that host stay inactive
  until you approve it; budgets without those fields need no approval.

## Onboarding

`iso-ci setup` is idempotent; repeat it with the step you need:

```sh
iso-ci setup --iso /usr/local/bin/iso --host local --write-config --repository OWNER/REPOSITORY
$EDITOR ~/.iso-ci/config.yaml
iso-ci setup --approve                 # shows each descriptor digest, then approves it
iso-ci setup --create-app              # GitHub App manifest flow in your browser
#   (or: --app-id ID --private-key app.pem to connect an App you own)
#   install the App on the repository or organization, then:
iso-ci setup --installation-id ID      # verifies account, scope and permissions
iso-ci setup --service install         # or run `iso-ci serve` yourself
iso-ci setup --smoke-workflow /tmp/iso-runner-smoke.yml
```

- `--host` accepts `local` or an alias from `iso host add`. The host's identity
  is pinned on first contact; a later change is refused until you re-enable it.
- The App requests Administration write (repository pools) or Self-hosted
  runners write (organization pools), Actions read and Metadata read; never
  Actions write. Its private key goes to the login keychain; there is no PAT or
  `gh` fallback. Installation is a separate step on GitHub.
- The keychain item is bound to the executable that stored it, so an unsigned
  or rebuilt `iso-ci` must store the App key again (`setup` says so).
- The callback of the manifest flow listens once on `127.0.0.1` with a random
  state and closes after the redirect or 15 minutes.
- The smoke workflow is written for you to review and commit yourself. Run it
  twice: `iso-ci inspect` must show different VMs and runner registrations.
- Workflows opt in with `runs-on: [self-hosted, linux, ARM64, iso-ci]` (plus
  the runner group for an organization pool).

A pool becomes active only when its descriptors are approved, its installation
is verified, and the GitHub-side checks pass. It stays inactive for a public
repository, a runner group open to public repositories, missing permissions,
a scope and label set already used by another pool, or `authority: privileged`.
`iso-ci status` shows each pool's reason and guarantees.

## Operating

```sh
iso-ci serve                 # controller in the foreground
iso-ci serve --install       # explicit per-user launchd service
iso-ci status [--json]
iso-ci pool pause POOL       # stop replenishing; assigned work continues
iso-ci pool drain POOL       # also retire idle runners; --abort stops assigned work
iso-ci pool remove POOL      # offboard owned resources; --remove-credentials is explicit
iso-ci logs TARGET [--follow]
iso-ci inspect TARGET
iso-ci abort TARGET
iso-ci results ALLOCATION [--save DIR]   # request a VM's results; save them once staged
iso-ci pool resume POOL
```

Results are exported only on request: `iso-ci results` before the VM
completes stages the archive the host collects from the guest user's
`~/iso-results` directory (bounded by the profile's `stop_grace_seconds` plus
`export_grace_seconds`); afterwards `--save DIR` copies it out. `inspect`
shows the export outcome separately from the job's.

An uncertain runner registration (its creation reply was lost and the exact
runner could not be found) blocks that allocation's capacity until you resolve
it: check the runner list on GitHub, then run
`iso-ci pool resolve ALLOCATION --runner-id ID` (the exact runner is deleted)
or `--none`. `iso-ci status` lists it under unresolved cleanup until then.

Closing a terminal never stops a job; `abort` does. A serving controller
starts each connected allocation in its own supervisor process (`iso-ci
internal-supervise`, in a new session), passing it the allocation's
`run/allocations/<id>.lock` already locked with `flock`. The supervisor
provisions the VM, registers the JIT runner, starts it, and then holds the
VM's access session until the controller stops, retains or releases it; the
kernel releases the lock when it exits. Restarting the controller (or `iso
update`) therefore neither interrupts a registration nor lets the host stop
a running VM: on start the controller re-adopts every allocation whose lock
is still held and leaves its startup to the supervisor. An allocation whose
supervisor died before the VM was ready is released; one that was ready
continues normally, and a lost registration reply is resolved by name as
before. If no supervisor and no controller hold a VM's session, its host
stops it after the lease grace period and enforces the hard deadline
regardless.

On SIGTERM or SIGINT the controller deletes its scale-set message sessions
before exiting. A session left open (a controller killed with SIGKILL) keeps
receiving the scale set's jobs on GitHub's side until it expires, and the
next controller's session sees none of them. If that happens, delete and
recreate the scale set, or wait for the session to expire.

`iso-ci status` shows the shared queue under `services.scheduler`: each
request with its state (`PLACED`, `QUEUED_WAITING_ROOM`,
`QUEUED_BEHIND_RESERVATION`, `QUEUED_WAITING_DRAIN`, `QUEUED_WAITING_VZ_SLOT`,
`QUEUED_NO_HOST`), each host's mode (`NORMAL`, `DRAINING_FOR_EXCLUSIVE`,
`EXCLUSIVE_BUSY`), its room reservation and the external use counted against
it. `iso-ci serve --record-protocol-trace FILE` appends a JSONL record (0600)
of scale-set sessions, messages, policy refusals, acquisitions, scheduling
rounds and allocation creation; it carries no tokens, queue URLs or JIT
material.

`--json` prints `{"ok":true,"result":...}` or `{"ok":false,"error":{"code":...}}`
with stable codes (for example `CAPABILITY_MISSING`, `OPERATION_UNCERTAIN`,
`REGISTRATION_UNCERTAIN`). Events are read by cursor.

The user service runs only while you are logged in. Sleep, restart and logout
stop it, and the GitHub App key in the login keychain is readable only while
the keychain is unlocked.

## Local preflight

```sh
iso-ci actions import actions/cache@v4         # once per approved action
iso-ci run .github/workflows/ci.yml --follow
iso-ci run .github/workflows/ci.yml --snapshot staged --follow --timeout 1800
iso-ci run .github/workflows/ci.yml --secret NPM_TOKEN=MY_NPM_TOKEN
iso-ci inspect RUN
iso-ci logs RUN --job JOB [--attempt N]          # that job's stored runner logs
```

`run` captures a snapshot of your working tree (tracked files with your
uncommitted edits, plus untracked paths you `--include`; local credential files
such as `.env`, `.env.*`, `.env-*`, `.env_*`, `.envrc`, `*.pem`, `*.jks`, `.npmrc`, `.pgpass`, `terraform.tfstate`,
`.config/gh/hosts.yml` and `.git-credentials` are excluded by default, matched
without regard to case). `run` lists the excluded paths for you; the snapshot
the job receives does not name them. Capture reads the Git index, `HEAD`, refs
and the repository's own `config` (for the `origin` URL that names the
repository) as data and never runs Git, so repository configuration, include
directives, hooks, filters and fsmonitor never execute or apply on the host. A
split or sparse index is refused (`git update-index --no-split-index` converts
a split one), as is a tracked path whose parent directory has been replaced by
a symlink. Only an explicit `--include` selects untracked files; ignore files
are not consulted. `run` then compiles the workflow against the `local-actions/v1`
compatibility manifest, and runs each job in its own clean VM through the
official runner. A workflow outside the manifest is refused with every problem
listed before any VM starts. With `--follow`, `run` exits non-zero unless the
run succeeds; `--timeout SECONDS` (with `--follow`) aborts a run that has not
settled by then and exits non-zero.

`--snapshot staged` captures exactly what the index stages for the next
commit instead of the working tree. Capture still reads files from the working
tree as data, never runs Git, and applies the same exclusions, but it checks
every tracked path against its staged blob: a path whose working-tree content,
executable bit or symlink target differs from the index, a staged path deleted
from the working tree, or a `git add -N` placeholder refuses the run and names
the paths. Stage them, or set the unstaged changes aside with
`git stash push --keep-index`. A staged snapshot never includes untracked
paths, so `--include` is refused with it. The default, `--snapshot
working-tree`, includes unstaged edits, so it does not check exactly what a
commit will contain.

The manifest covers: `run` steps with shell, environment, working directory,
defaults, timeouts and `continue-on-error`; approved JavaScript and composite
actions (`actions/checkout`, `actions/cache`, `actions/upload-artifact`,
`actions/download-artifact`) and local or `docker://` actions; `needs`,
static matrices, `if:` and job outputs; job and service containers on the
guest's own Docker. It refuses reusable workflows, dynamic matrices,
`environment:`, OIDC (`id-token: write`), container credentials, more than one
checkout, submodules, LFS, and any `runs-on` you have not mapped in
`platform_map`, except the built-in `[self-hosted, linux, ARM64]` set. ARM64 preflight is never presented as equivalent to an x86 or
macOS hosted runner.

How a job sees your code:

1. An approved `actions/checkout` becomes a visible **iso-ci checkout** step that
   prepares the workspace (no network). The snapshot (`iso-ci.snapshot/v2`)
   carries selected content only: no base-commit bundle and no history, so
   files excluded from it (credential-looking names by default) cannot be
   recovered from history in the job. A checkout that needs history
   (`fetch-depth` other than 1, `fetch-tags: true`) is refused as an
   unsupported capability. Recapture snapshots made by an older iso-ci.
2. A visible **iso-ci overlay** step applies the snapshot (contents, modes and
   permitted symlinks) and verifies it, then, where git exists, records it as
   one synthetic commit. That commit is the job's own and is not the base
   commit; the base commit is kept only as provenance. Without a checkout the
   overlay is the first step.

The snapshot digest identifies what you supplied at that boundary; later steps
can still change their own workspace. A run that includes uncommitted changes
is labelled so: its success is not evidence that the base commit passes.

The job's VM has no general network. It reaches one service: the run's local
endpoint, carried inside that VM's own SSH session, which serves the runner
protocol, approved action archives, the snapshot, caches, artifacts and logs.
Each request is authorized for that allocation alone. A runner that does not
acquire its job within the profile's `boot_seconds` fails the attempt instead
of holding its VM. The endpoint runs in a
confined child process with no credentials, no network and access only to its
staging directory; if that confinement cannot be established, preflight is
refused. Caches are partitioned by repository, authority, platform, image,
runner version and workflow digest; the first complete upload of a key wins,
and incomplete uploads are never visible. Only a run of a clean tree without
mapped secrets saves shared cache entries: a run with uncommitted, included
untracked or patched content, or with `--secret`, keeps its cache entries to
itself, so a later run of the clean base never restores them. Artifacts are scoped to their run and
can be downloaded only by jobs that depend on the producing job.

Job and service containers need their images. With the template's
`egress: none`, the guest's Docker cannot pull them. For container jobs, give
the preflight network policy `egress: filtered` with only your registries in
`required_hosts` (for example `ghcr.io` and
`pkg-containers.githubusercontent.com`, covered by the host's allowlist). The
Docker daemon pulls through the egress companion. The runner and its
containers get no proxy and reach only the endpoint, which an image with
Docker also serves on Docker's gateway (`172.17.0.1`) because a container's
loopback is not the guest's. The synthetic steps are POSIX `sh` and fetch the
snapshot with curl or wget, so they run in minimal containers. In a container
without git the checkout leaves no `.git`, as GitHub's checkout does there.
The guest's runner user is not GitHub-hosted's uid 1001: an image whose
default user is another non-root uid needs `options: --user root` (or a
matching uid) to write the workspace.

Failed jobs are kept running for `live_retention_seconds` (host-enforced) so you
can look and try a fix:

```sh
iso-ci debug ALLOCATION                         # ssh into the retained VM
iso-ci patch ALLOCATION --from-working-tree     # apply your current tree there
iso-ci retry ALLOCATION --from-start            # fresh VM, whole job
```

`patch` records a new input revision and never rewrites earlier ones. `retry`
always starts a clean VM from the first step; failed-step continuation is not
supported. When a retried job's dependencies ran on an earlier revision, the
result is reported as mixed-input, not as one clean run. Replaying a connected
job is a separate local run and never changes a GitHub check.

### Running a project's CI from its Git hooks

`iso-ci hooks` makes local preflight a check in your own project's Git hooks:
on a protected branch, a commit (or push) is blocked unless the project's
workflow passes in disposable iso VMs. Other branches skip the hook. It runs
the project's CI, not iso's, and needs a working local preflight setup (see
[Before you start](#before-you-start)): an installed `iso-ci`, an approved
preflight profile and image, a qualified host, and any approved actions the
workflow uses.

```sh
cd ~/src/my-project
iso-ci hooks install --dry-run                  # show what would change
iso-ci hooks install                            # pre-commit on main, .github/workflows/ci.yml
iso-ci hooks install --hook pre-push --branch trunk --timeout 3600
iso-ci hooks status
iso-ci hooks uninstall [--hook pre-commit]
```

`install` writes a POSIX `sh` hook meant to be committed with the project. By
default it goes in `.githooks/` and iso-ci sets `git config --local
core.hooksPath .githooks`; each collaborator who wants the check runs that
same `git config` command once. Options: `--hook pre-commit|pre-push`,
`--branch` (default `main`), `--workflow` (default `.github/workflows/ci.yml`),
`--event` (default `push`), `--snapshot` (default `staged`), `--timeout`
(default 1800 seconds) and `--directory` (when `core.hooksPath` is not set).
The hook names no path on your Mac; it runs `iso-ci` from `PATH`, or from
`ISO_CI` when set (Git GUI clients often run hooks with a short `PATH`).

Existing hooks are not overwritten silently. `install` refuses:

- a hook file iso-ci did not write. `--force` replaces it and keeps it as
  `<hook>.iso-ci-backup`, which `uninstall` restores;
- moving `core.hooksPath` while `.git/hooks` holds active hooks, which would
  stop them running (move them into the project hooks directory first);
- a `core.hooksPath` from your user or system Git configuration, which a local
  setting would bypass for this repository;
- `--directory` that differs from a `core.hooksPath` the repository already
  sets.

To use a hook manager instead (pre-commit, lefthook, husky), call
`iso-ci run .github/workflows/ci.yml --snapshot staged --follow --timeout
1800` from its configuration. `uninstall` removes only hooks iso-ci wrote, and
unsets `core.hooksPath` only when iso-ci set it and the directory holds no
other hook.

What each hook checks:

| Hook | Runs when | Checks |
|---|---|---|
| `pre-commit` | committing on the protected branch | The staged index (`--snapshot staged`), so it checks exactly what the commit will contain, or refuses. |
| `pre-push` | pushing to `refs/heads/<branch>` | The checked-out commit. It refuses a push of a commit other than `HEAD`, and staged changes, which the pushed commit does not contain. |

| You run | Result |
|---|---|
| `git commit` on the protected branch; the workflow passes | The commit proceeds |
| `git commit` on the protected branch; a job fails, the workflow is refused, the run times out, or `iso-ci` is missing | The commit is blocked, with the reason |
| `git commit` on another branch | The hook skips local preflight |
| `git commit --no-verify` | Git skips the hook |

A run takes as long as the workflow does and starts one VM per job, so a
team may prefer the `pre-push` hook, or a manual `iso-ci run`, and keep only
quick checks in `pre-commit`. Failed jobs stay inspectable with `iso-ci
inspect` and `iso-ci logs` as above. Secrets are never imported automatically:
a workflow that needs one still needs `--secret NAME=ENV_VAR` in a manual run,
and a hook passes none. Local preflight runs Linux ARM64 jobs only. Your
hosted CI stays authoritative: a local pass is not evidence for a hosted x86 or
macOS job.

## Credentials and trust

Every guest is treated as hostile.

| Material | Where it lives | Reaches a guest? |
|---|---|---|
| GitHub App private key | Login keychain (`dev.iso.ci`) | Never |
| Installation access tokens | Controller memory, each narrowed to the repository and permissions its call needs | Never |
| Runner JIT configuration | Sent once over the VM's SSH session on stdin | Yes, by design (it registers that one runner) |
| `GITHUB_TOKEN` and repository secrets (connected) | Issued by GitHub to the job | Yes, as GitHub decides |
| Preflight per-allocation credentials | Controller memory | Yes; they authorize only that allocation's local endpoint |
| Preflight secrets | `--secret NAME=ENV_VAR` per run, controller memory until the run finishes (a later `retry` asks you to resubmit) | Yes, only the ones you map |
| iso host-management keys, tailnet credentials | Untouched by iso-ci | Never |

A pool's `validation` authority describes the grants iso-ci gives; it cannot
reduce GitHub's `GITHUB_TOKEN` permissions or withhold repository secrets.
`iso-ci status` lists each pool's GitHub-side guarantees as verified,
operator-attested or unavailable. Public repositories and forks are separate
support claims: repository privacy never grants them.

Fork execution and privileged release execution are refused, not supported.
A warm pool cannot see which job its runner will get, so a warm pool whose
repository is public, or whose runner group admits public repositories, stays
inactive. A scale-set pool sees each job before acquiring it, so it may opt
into public repositories with `allow_public_repo: true` under the bounds in
[scale sets and shared hosts](#scale-sets-and-shared-hosts); fork pull
requests stay refused per job. An `authority: privileged` pool stays inactive
even after `pool resume`.

A scale-set pool's controller talks to GitHub's Actions service
(`*.actions.githubusercontent.com`) with an admin token from a runner
registration token and with its message-session token. Both stay in
controller memory, go only to `https` hosts under that suffix, and never
reach a guest; the guest receives only the JIT configuration, as for warm
pools.

Stopping admission or revoking a grant does not erase secrets already in a
guest's memory, files, logs or retained disk. Log masking is defense in depth.

## Failures and recovery

| Condition | What iso-ci does |
|---|---|
| A host mutation's reply is lost | Queries or resends the same operation id; never creates a second VM |
| A runner registration's reply is lost | Looks up the exact owned runner; if ownership can't be established, marks it `registration uncertain` for you to resolve |
| A host is unreachable | Marks its allocations unknown, keeps their budget reserved, admits nothing new there |
| GitHub is unavailable or the App is revoked | Pauses the affected pools with bounded retries; local limits stay in force |
| The brokered proof fails | The host revokes access; the allocation is stopped; there is no NIC fallback |
| Abort or expiry | External stop, permitted diagnostics staged, cleanup requested and verified |
| A job's outcome is unknown | No automatic replay of side-effecting work |
| The controller restarts | Live supervisors keep their allocations; the controller re-adopts them and does not touch their startup |
| A supervisor dies | Before the VM was ready: the allocation is released. After: the controller holds the session and runs the lifecycle |
| A scale-set job fails the job policy | Not acquired; no VM or registration; a `job.rejected` event with its code |
| The scale-set session or token expires | The session is refreshed or recreated; jobs GitHub assigned meanwhile are counted from its statistics |

Cleanup that cannot be verified stays in `status` as unresolved cleanup and
keeps consuming budget until a later pass verifies it.

## Offboarding

`iso-ci pool remove POOL` stops replenishment, retires idle runners, waits for
assigned work, deletes only this controller's exact runner registrations, and
destroys only its own VMs, recording any cleanup it cannot verify. It never
removes iso enrollment, other VMs, other controllers' runners or unrelated App
installations. `--remove-credentials` also deletes the App key from the
keychain when no other pool uses it; the App and its installation remain on
GitHub for you to remove. `iso-ci serve --uninstall` removes the user service.

## Qualifying your hosts

iso-ci admits work only on hosts with current NET-HANDOFF-1 evidence; the
[qualification record](design/iso-ci-qualification.md) lists what has run
and where. Before relying on a pool or on preflight results, run on each
host/profile you use:

- the NET-HANDOFF-1 evidence for the host tuple (required: admission refuses
  without it);
- the connected acceptance cases C-T01–C-T08 and C-T14–C-T18 with real GitHub
  jobs (two consecutive jobs in different VMs and registrations, lost JIT
  response, drain/assignment races, offboarding);
- the preflight cases C-T09–C-T13 with the pinned official runner;
- `iso-ci/scripts/test-dataplane-jail.sh` for the data-plane confinement.

The acceptance cases are defined in
[specification section 14](design/iso-ci-specification.md#14-acceptance-tests).
