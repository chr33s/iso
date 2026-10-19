#!/usr/bin/env python3
"""N-T05: a malicious SSH server cannot turn iso's static forwards or its
stream connector into arbitrary host connections or host execution.

A paramiko server stands in for a hostile guest sshd. iso's ssh client (the
option set of SSHTarget.transportOptions, reached through a ProxyCommand as a
brokered guest is) requests one static reverse forward, exactly as
ProxyLifecycle does for a broker. The server then:

- opens the forwarded channel it was granted (positive control: the host's
  broker listener receives exactly that connection);
- opens a forwarded channel for a port the client never requested;
- opens direct-tcpip to a host canary, an agent channel, and an X11 channel.

Every illegitimate open must be refused by the client and the canary must
see no connection. Needs OpenSSH, nc and paramiko; without paramiko the
check is reported as blocked (exit 2), never as passed.

Usage: python3 tests/brokered_malicious_ssh.py   (any python with paramiko)
"""
import json
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

try:
    import paramiko
except ImportError:
    print("BLOCKED  N-T05: paramiko is not installed (pip install paramiko)")
    sys.exit(2)


class Listener:
    """A host TCP listener that counts and answers connections."""

    def __init__(self):
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.port = self.sock.getsockname()[1]
        self.hits = 0
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            self.hits += 1
            try:
                conn.sendall(b"ok\n")
            finally:
                conn.close()


class HostileGuest(paramiko.ServerInterface):
    def __init__(self, client_key):
        self.client_key = client_key
        self.forwarded = threading.Event()
        self.bound = None

    def get_allowed_auths(self, username):
        return "publickey"

    def check_auth_publickey(self, username, key):
        if key.get_base64() == self.client_key:
            return paramiko.AUTH_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def check_port_forward_request(self, address, port):
        self.bound = (address, port)
        self.forwarded.set()
        return port

    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED


def refused(open_channel):
    try:
        channel = open_channel()
    except Exception:  # paramiko raises ChannelException on a refusal
        return True
    channel.close()
    return False


def main():
    work = Path(tempfile.mkdtemp(prefix="iso-nt05-"))
    for name in ("client", "host"):
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(work / name)],
                       check=True)
    client_pub = (work / "client.pub").read_text().split()[1]
    host_key = paramiko.Ed25519Key(filename=str(work / "host"))
    alias = "iso-0a1b2c3d-00112233445566ff.iso"
    (work / "known_hosts").write_text(f"{alias} ssh-ed25519 {host_key.get_base64()}\n")

    broker = Listener()  # the host-side broker a static forward targets
    canary = Listener()  # an unrelated host service
    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    guest = HostileGuest(client_pub)
    transport_box = {}

    def accept():
        conn, _ = server.accept()
        transport = paramiko.Transport(conn)
        transport.add_server_key(host_key)
        transport.start_server(server=guest)
        transport_box["t"] = transport

    threading.Thread(target=accept, daemon=True).start()
    guest_port = 18788
    # SSHTarget.transportOptions, with the brokered ProxyCommand shape.
    argv = [
        "ssh", "-F", "/dev/null",
        "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=3", "-o", "StrictHostKeyChecking=yes",
        "-o", f"UserKnownHostsFile={work / 'known_hosts'}", "-o", "GlobalKnownHostsFile=/dev/null",
        "-o", f"HostKeyAlias={alias}", "-o", "UpdateHostKeys=no", "-o", "ForwardAgent=no",
        "-o", "IdentityAgent=none",
        "-o", f"ProxyCommand=/usr/bin/nc 127.0.0.1 {server.getsockname()[1]}",
        "-o", "IdentitiesOnly=yes", "-o", "LogLevel=ERROR", "-i", str(work / "client"),
        "-o", "ExitOnForwardFailure=yes", "-N",
        "-R", f"127.0.0.1:{guest_port}:127.0.0.1:{broker.port}",
        f"ubuntu@{alias}",
    ]
    client = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, env={"PATH": "/usr/bin:/bin", "HOME": str(work)})
    evidence = {}
    try:
        if not guest.forwarded.wait(20):
            print("FAIL     N-T05: the client never requested its reverse forward")
            return 1
        transport = transport_box["t"]
        # Positive control: the granted forward reaches the broker, and only it.
        control = transport.open_forwarded_tcpip_channel(("10.0.0.9", 40000), ("127.0.0.1", guest_port))
        control.settimeout(10)
        evidence["control_reply"] = control.recv(16).decode(errors="replace").strip()
        control.close()
        evidence["unrequested_forward_refused"] = refused(
            lambda: transport.open_forwarded_tcpip_channel(("10.0.0.9", 40001), ("127.0.0.1", canary.port)))
        evidence["direct_tcpip_refused"] = refused(
            lambda: transport.open_channel("direct-tcpip", ("127.0.0.1", canary.port), ("10.0.0.9", 40002)))
        evidence["agent_channel_refused"] = refused(
            lambda: transport.open_channel("auth-agent@openssh.com"))
        evidence["x11_channel_refused"] = refused(
            lambda: transport.open_channel("x11", src_addr=("10.0.0.9", 6000)))
        time.sleep(1)
        evidence["broker_hits"] = broker.hits
        evidence["canary_hits"] = canary.hits
    finally:
        client.terminate()
        try:
            client.wait(10)
        except subprocess.TimeoutExpired:
            client.kill()
    print(json.dumps(evidence, sort_keys=True))
    checks = [
        ("the granted forward reaches only its fixed broker", evidence.get("control_reply") == "ok"
         and evidence.get("broker_hits") == 1),
        ("an unrequested forwarded port is refused", evidence.get("unrequested_forward_refused")),
        ("server-initiated direct-tcpip is refused", evidence.get("direct_tcpip_refused")),
        ("agent and X11 channels are refused",
         evidence.get("agent_channel_refused") and evidence.get("x11_channel_refused")),
        ("no host service outside the forward is reached", evidence.get("canary_hits") == 0),
    ]
    failed = 0
    for label, ok in checks:
        print(("PASS     " if ok else "FAIL     ") + "N-T05: " + label)
        failed += not ok
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
