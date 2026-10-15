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
