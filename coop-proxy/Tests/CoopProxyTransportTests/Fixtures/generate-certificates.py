#!/usr/bin/env python3
"""Generate disposable localhost TLS fixtures; never changes system trust."""
from datetime import datetime, timedelta, timezone
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
root.mkdir(mode=0o700, parents=True, exist_ok=True)
(root / "index").write_text("")
(root / "index.attr").write_text("unique_subject = no\n")
(root / "serial").write_text("1000\n")
(root / "ca.conf").write_text("""
[ca]
default_ca = authority
[authority]
database = index
serial = serial
new_certs_dir = .
certificate = ca.pem
private_key = ca.key
default_md = sha256
default_days = 365
policy = policy
unique_subject = no
[policy]
commonName = supplied
[req]
distinguished_name = dn
[dn]
[root]
basicConstraints = critical,CA:true
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
subjectAltName = DNS:localhost
""")


def run(*args):
    subprocess.run(["/usr/bin/openssl", *args], cwd=root, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=15)


run("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key",
    "-out", "ca.pem", "-days", "3650", "-subj", "/CN=coop disposable test CA",
    "-config", "ca.conf", "-extensions", "root")
run("genrsa", "-out", "server.key", "2048")
run("req", "-new", "-key", "server.key", "-out", "server.csr",
    "-subj", "/CN=localhost", "-config", "ca.conf")
now = datetime.now(timezone.utc)
for name, host, start, end in [
    ("valid", "localhost", now - timedelta(days=1), now + timedelta(days=364)),
    ("wrong-host", "wrong.invalid", now - timedelta(days=1), now + timedelta(days=364)),
    ("expired", "localhost", now - timedelta(days=366), now - timedelta(days=1)),
    ("future", "localhost", now + timedelta(days=1), now + timedelta(days=365)),
]:
    (root / "leaf.ext").write_text("basicConstraints = critical,CA:false\n"
        "keyUsage = critical,digitalSignature,keyEncipherment\n"
        "extendedKeyUsage = serverAuth\nsubjectAltName = DNS:" + host + "\n")
    run("ca", "-batch", "-config", "ca.conf", "-in", "server.csr", "-out", name + ".pem",
        "-notext", "-extfile", "leaf.ext", "-startdate", start.strftime("%y%m%d%H%M%SZ"),
        "-enddate", end.strftime("%y%m%d%H%M%SZ"))

# A well-formed self-signed server leaf, with the same localhost SAN and usage
# constraints as the valid CA-issued leaf, isolates the missing-anchor failure.
run("x509", "-req", "-in", "server.csr", "-signkey", "server.key", "-out", "self-signed.pem",
    "-days", "365", "-extfile", "leaf.ext")
