"""Root helper: hand one loopback HTTPS listener to the unprivileged test owner.

The parent creates a private Unix socket and explicitly invokes this helper with
sudo. After binding it drops privileges and waits for the listener lease to end.
No credentials, certificates, guest bytes, or HTTP handling enter here.
"""
import array
import os
from pathlib import Path
import socket
import stat
import sys

path = Path(sys.argv[1])
assert os.geteuid() == 0, "requires root only to bind port 443"
owner = int(os.environ["SUDO_UID"])
parent = path.parent.stat()
assert parent.st_uid == owner and stat.S_IMODE(parent.st_mode) == 0o700
entry = path.lstat()
assert stat.S_ISSOCK(entry.st_mode) and entry.st_uid == owner
with socket.socket() as listener, socket.socket(socket.AF_UNIX) as control:
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 443))
    listener.listen(8)
    # Retain the socket creator for the lease: on macOS, TLS on transferred
    # sockets can reset after the creator exits. No privileged work remains.
    os.setgroups([])
    os.setgid(int(os.environ["SUDO_GID"]))
    os.setuid(owner)
    control.connect(str(path))
    control.sendmsg([b"listener"], [(socket.SOL_SOCKET, socket.SCM_RIGHTS,
                                   array.array("i", [listener.fileno()]))])
    control.settimeout(3600)
    try:
        control.recv(1)
    except socket.timeout:
        pass
