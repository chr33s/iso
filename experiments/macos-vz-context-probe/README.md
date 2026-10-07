# macOS VZ context probe

Harness for
[`macos-vz-context-headless-experiment-spec.md`](../../docs/design/macos-vz-context-headless-experiment-spec.md):
which host process/session/UI context a macOS `VZVirtualMachine` and its
`VZVirtualMachineView` need. It is experiment code and is not part of the
shipped product. `mise run lint` format-checks its Swift sources; nothing in
the gates builds or tests it. Results are in
[`docs/design/macos-vz-context-experiment.md`](../../docs/design/macos-vz-context-experiment.md).

## Parts

- **`vz-context-probe`** (host, signed with `com.apple.security.virtualization`):
  - `report-context`: pid/ppid, uid/euid/gid, `HOME`, launchd manager, whether
    `user/$UID` and `gui/$UID` exist, console user and lock state, security
    session attributes, virtualization support and entitlement, and keychain
    metadata only (spec §8).
  - `VMHost` (shared by both owners): one VM built with
    `VZVirtualMachine(configuration:queue:)` on an explicit serial queue. Every
    VZ call is made on that queue. It handles state observation, start and the
    stop sequence. To stop, it calls `requestStop` and waits 60 s. If the guest
    is still running, it asks the guest helper to shut down and waits 120 s. If
    that also fails, it calls `stop()`. The path taken is recorded as
    `stop_path`. A stop counts as graceful only if the VM was running when the
    stop was requested and `stopped` was reached without `stop()`. Each VM
    gets a new instance ID.
  - `vm-run`: the headless Phase 1/2 owner. It never touches AppKit, a view or
    WindowServer, although AppKit is linked into the same binary. Each cycle
    validates, starts and waits for `running`. It then waits for the guest
    helper's vsock hello and the guest's SSH banner, holds, and stops. Events
    go to `vm-events.jsonl` and live state to `status.json`. The exit status
    is 0 only if every cycle passed.
  - `vm-view`: the Phase 3/4 owner. The VM runs on its own queue and the view
    connects through `VZVirtualMachineViewAdaptor` with
    `automaticallyReconfiguresDisplay = false`, in topology V0–V8. A 0600
    Unix socket serves frames (O1 `cacheDisplay`, plus a diagnostic walk of the
    private layer tree), sessions bound to the guest boot identity and to the
    VM instance, input, and `restart_vm`, which replaces the VM inside the same
    owner.
    Input is synthesized `NSEvent`s handed to the view's responder methods.
    A right click needs an NSEvent built from a `CGEvent` (`source: cgevent`),
    because `NSEvent.mouseEvent` cannot set the button number. The CGEvent is
    never posted. Nothing is posted to the host event system.
  - `analyze-frame`: runs as a separate process. It decodes the fixture's token
    and frame counter barcodes from a captured PNG and finds the grid's magenta
    corner markers in the pixels.
  - `sck-capture`: the O2 ScreenCaptureKit diagnostic control, run as its own
    process so it uses its own Screen Recording permission.
  - `ssh-banner <ip>`: a diagnostic. It compares the `/usr/bin/nc` banner check
    with a direct connect from this process, which Local Network privacy can
    block.
- **`IsoVZProbe.app`** (guest fixture): shows the run token, a 250 ms frame
  counter, a 10×10 grid (A01–J10), a text field, a key display, a drag
  source with targets D01–D08, and a scroll region. It writes
  `~/Library/Application Support/IsoVZProbe/state.json` atomically and
  appends to `events.jsonl`. It logs and swallows Command key-downs so Cmd-Q
  cannot end it.
- **`iso-vz-probe-helper`** (guest LaunchDaemon, root, runs before login):
  connects to host vsock port 7701 and answers the host's `nonce` challenge
  with `{"hello":1,"boot":…,"build":…,"fixture":…,"mac":…}`. The `mac` field
  is HMAC-SHA256 over `nonce|boot`, keyed with the bundle's `helper.key`
  (host copy mode 0600; guest copy at `/usr/local/etc`, mode 0600 root). The
  host accepts only authenticated hellos, from at most 4 pending connections
  at a time, so a guest process without the key cannot supply or replace the
  boot identity.
  It accepts one host command, `shutdown`, and runs `shutdown -h now` in
  response. That gives the guest a clean stop path when `requestStop` is
  ignored.

## Running

The harness reuses the preinstalled guest that the Q0 spike installed
(`$VZPROBE_VM`, default `~/.iso-q0/vm`), keeping the same hardware model,
machine identifier, auxiliary storage and disk (spec §6.1). Results go to
`$VZPROBE_STATE/results/<run-id>/` (default `~/.iso-vz-probe`) in the spec §18
layout. C3–C5 runs are the exception, because a daemon owns them. The owner
writes to `/Library/Application Support/iso-vz-probe/results/<run-id>/`, `metadata.json` stays
in the plan directory, and `collect` writes `result.json` next to the owner's
files when it can, or under `$VZPROBE_STATE/results/<run-id>/` otherwise.

```sh
./build.sh
./probe.py bootstrap-guest                   # fixture app + helper daemon, guest sleep off
./probe.py phase1 --context C1 --runs 10     # C0 direct, C1 user/$UID Background, C2 gui/$UID Aqua
./probe.py phase2 --context C1               # lock / display sleep / wake; --operator-wait S for S4-S6
./probe.py phase3 --topology V5 --domain user --captures 1000 --clicks 1000
./probe.py phase4 --topology V6              # computer use across lock / display sleep
./probe.py e9 --topology V6 --domain user    # guest reboot and VM replacement invalidate sessions
./probe.py auth-check                        # forged vsock hellos are rejected
./probe.py report                            # results/summary.md
```

C3–C5 (system LaunchDaemons) need root. C4 and C5 also need a dedicated
standard user, `iso-vz-test`. `daemon-plan` writes the plist and an install
script for the operator to run with `sudo`. The script clones the VM bundle
into `/Library/Application Support/iso-vz-probe`. That directory is
root-owned, and the script refuses a pre-existing directory that is not.
Never run the clone at the same time as the original. For C5, the script
installs the daemon without loading it. Then shut down, power on, do not log
in, wait, and only then log in and run `collect … --boot-log`:

```sh
./probe.py daemon-plan --context C5 --cycles 1
sudo ~/.iso-vz-probe/daemon/<run-id>/install.sh
./probe.py collect '/Library/Application Support/iso-vz-probe/results/<run-id>' --boot-log
```

The guest sudo password is read from `$VZPROBE_GUEST_PASSWORD` or the Q0
harness's file outside the repository, and is passed only over SSH stdin.
Keychain state is recorded as metadata and is never unlocked or read.
