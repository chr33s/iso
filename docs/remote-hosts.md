# Remote Macs

Run a project's Linux VM on another trusted Apple Silicon Mac while keeping
your editor and terminal on your own machine.

## Prepare the remote Mac

Install the same isolate build on both Macs. On the remote Mac, complete the
[Apple backend prerequisites](backends.md#prerequisites) and run `iso setup`.
Allow Local Network access for `iso` when macOS asks; the host service needs it
to connect to its guests.

Configure an SSH alias for the remote Mac, then enroll it from your client:

```sh
iso host add build-mac --ssh build-mac --agent-path /Users/me/.local/bin/iso
```

Replace the agent path with the absolute path to the installed remote `iso`.
Enrollment verifies the host's installation identity over pinned SSH. Your
SSH key for the remote Mac may live in your SSH agent (a passphrase-protected
key, 1Password or Secretive); iso uses the agent only to authenticate to that
Mac and never forwards it, and VM sessions never use it.

The remote Mac's own configuration decides how its VMs are connected. With
[`"network": {"transport": "brokered"}`](configuration.md#network) there, new
VMs it creates have no network device, and its relay reaches each guest
through the runtime's stream connector instead of the guest's address; the
client's pinned SSH, session leases and revocation are unchanged. Requests
for `--egress open` are then refused. Existing VMs keep the transport they
were created with. `iso host vm inspect` shows a running brokered VM's
network proof from a fresh check on the remote Mac: zero external network
devices and the boot's network-policy and channel-policy digests. A brokered
VM that fails that check is reported `unhealthy`, and a client refuses a proof
that is malformed, names another boot or reports a network device. The proof is
an observation; every access is checked again on the remote Mac.

### Brokered handoff evidence

A companion that needs a brokered VM (for example a CI runner pool) asks the
host's `host.capabilities` and requires `net-handoff-1`. A brokered host lists
it only with current qualification evidence for its exact tuple. After running
the brokered qualification suite (N-T01–N-T16) on that Mac, record its
results there:

```sh
python3 scripts/record-net-handoff-evidence.py --results results.json
```

The script refuses results with any case not `passed` and installs a private
manifest that expires (90 days by default, at most 365). The evidence covers
the one image it names (`tuple.image`, `<name>@sha256:<hex>`); a companion
binds its VMs to that image by requesting its digest, which the host
enforces. Updating iso, the runtime or macOS, or rebuilding the qualified
image, withdraws the capability until new evidence is recorded. Details:
[NET-HANDOFF-1](design/brokered-network-isolation.md).

Companions reach a host through `iso host-agent client --host ALIAS --stdio`
(and `--relay` for one guest stream) rather than reading iso's files. Against
`local` it applies the same restrictions as a remote client.

## Start a project

```sh
cd ~/code/my-project
iso host up build-mac . --name my-project
iso host shell build-mac my-project
```

Unlike local `iso up`, every `iso host up` pushes the project, including when
reusing a VM. Use [workspace transfer commands](commands.md#host) to control
later synchronization and stage returned files before applying them.

For an agent session:

```sh
iso host agent build-mac my-project claude
# or
iso host agent build-mac my-project codex
```

Remote agent sessions require the client's credential proxy; configure its
[provider upstreams](credential-proxy.md) first. Provider credentials stay in
that client-side proxy.

## Stop or remove the VM

```sh
iso host vm stop build-mac my-project
iso host vm destroy build-mac my-project
```

Stopping preserves the disk. Destroying deletes the VM, so bring back any
guest-only work first. Removing a host enrollment does not delete its VMs.
See the [host command reference](commands.md#host) for sessions, forwarding,
image management, and operation recovery.
