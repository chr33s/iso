# iso-ci: isolated GitHub Actions execution

`iso-ci` is a separately installed companion to iso. It runs GitHub Actions
jobs in clean, NIC-less iso VMs on your own Apple Silicon Macs, in two modes:

| Mode | Who decides what runs | What iso-ci does |
|---|---|---|
| **GitHub-connected pool** | GitHub | Keeps a bounded number of fresh, single-use official runners ready. GitHub assigns jobs, records checks, and keeps its normal caches and artifacts. |
| **Local preflight** | iso-ci | Compiles a workflow from the supported subset, captures your working tree as an immutable snapshot, and runs each job through the official runner against local services. You can inspect, debug, patch and rerun a job from the start. |

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
   iso setup --profile ci-runner --name ci-runner
   ```

   The image holds the official Actions runner (pinned version and SHA-256)
   on iso's base image with Docker and the SSH server. It contains no runner
   registration, project state, caches, App material or provider credentials.

To use another Mac, enroll it with iso first
(`iso host add ...`, [remote hosts](remote-hosts.md)). iso-ci uses iso's
enrollment and pinned SSH; it never discovers tailnet nodes, and job VMs never
join a tailnet.

Build and install iso-ci:

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
schema: iso-ci/v1

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
- `platform` is `linux/arm64`. There is no implicit architecture translation;
  preflight maps a `runs-on` label only through `platform_map`.
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

The controller holds the VM leases. Closing a terminal never stops a job;
`abort` does. If the controller itself stops, each host stops its VMs after
the lease grace period and enforces the hard deadline regardless.

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
iso-ci run .github/workflows/ci.yml --secret NPM_TOKEN=MY_NPM_TOKEN
iso-ci inspect RUN
iso-ci logs RUN --job JOB [--attempt N]          # that job's stored runner logs
```

`run` captures a snapshot of your working tree (tracked files with your
uncommitted edits and deletions, plus untracked paths you `--include`; local
credential files such as `.env*`, `*.pem`, `.npmrc` and `.git-credentials` are
excluded by default), compiles the workflow against the `local-actions/v1`
compatibility manifest, and runs each job in its own clean VM through the
official runner. A workflow outside the manifest is refused with every problem
listed before any VM starts. With `--follow`, `run` exits non-zero unless the
run succeeds.

The manifest covers: `run` steps with shell, environment, working directory,
defaults, timeouts and `continue-on-error`; approved JavaScript and composite
actions (`actions/checkout`, `actions/cache`, `actions/upload-artifact`,
`actions/download-artifact`) and local or `docker://` actions; `needs`,
static matrices, `if:` and job outputs; job and service containers on the
guest's own Docker. It refuses reusable workflows, dynamic matrices,
`environment:`, OIDC (`id-token: write`), container credentials, more than one
checkout, submodules, LFS, and any `runs-on` you have not mapped in
`platform_map`. ARM64 preflight is never presented as equivalent to an x86 or
macOS hosted runner.

How a job sees your code:

1. An approved `actions/checkout` becomes a visible **iso-ci checkout** step that
   restores the base commit from a bundle inside the snapshot (no network).
2. A visible **iso-ci overlay** step applies the snapshot (contents, modes,
   permitted symlinks and deletions) and verifies it. Without a checkout it is
   the first step.

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
and incomplete uploads are never visible. Artifacts are scoped to their run and
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

## Credentials and trust

Every guest is treated as hostile.

| Material | Where it lives | Reaches a guest? |
|---|---|---|
| GitHub App private key | Login keychain (`dev.iso.ci`) | Never |
| Installation access tokens | Controller memory | Never |
| Runner JIT configuration | Sent once over the VM's SSH session on stdin | Yes, by design (it registers that one runner) |
| `GITHUB_TOKEN` and repository secrets (connected) | Issued by GitHub to the job | Yes, as GitHub decides |
| Preflight per-allocation credentials | Controller memory | Yes; they authorize only that allocation's local endpoint |
| Preflight secrets | `--secret NAME=ENV_VAR` per run, controller memory | Yes, only the ones you map |
| iso host-management keys, tailnet credentials | Untouched by iso-ci | Never |

A pool's `validation` authority describes the grants iso-ci gives; it cannot
reduce GitHub's `GITHUB_TOKEN` permissions or withhold repository secrets.
`iso-ci status` lists each pool's GitHub-side guarantees as verified,
operator-attested or unavailable. Public repositories and forks are separate
support claims: repository privacy never grants them.

Public and fork execution and privileged release execution are refused, not
supported. GitHub does not let the installation verify fork approval or
per-job admission, so a pool whose repository is public, or whose runner group
admits public repositories, stays inactive, and an `authority: privileged`
pool stays inactive even after `pool resume`.

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
