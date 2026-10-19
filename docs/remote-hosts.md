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
Enrollment verifies the host's installation identity over pinned SSH.

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
