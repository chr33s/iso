#!/usr/bin/env python3
"""Generate disposable TLS fixtures for both proxy implementations."""
from pathlib import Path
import subprocess
import sys
import tempfile

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="coop-forward-ca-") as temporary:
    work = Path(temporary)

    def openssl(*args):
        subprocess.run(["openssl", *args], cwd=work, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key",
            "-out", "ca.pem", "-days", "2", "-subj", "/CN=coop test CA",
            "-addext", "basicConstraints=critical,CA:TRUE")
    openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "leaf.key",
            "-out", "leaf.csr", "-subj", "/CN=api.anthropic.com")
    (work / "extensions").write_text(
        "basicConstraints=critical,CA:FALSE\n"
        "keyUsage=critical,digitalSignature,keyEncipherment\n"
        "extendedKeyUsage=serverAuth\n"
        "subjectAltName=DNS:api.anthropic.com,DNS:api.openai.com\n")
    openssl("x509", "-req", "-in", "leaf.csr", "-CA", "ca.pem", "-CAkey", "ca.key",
            "-CAcreateserial", "-days", "1", "-extfile", "extensions", "-out", "leaf.pem")
    extensions = (work / "extensions").read_text()
    (work / "wrong.ext").write_text(extensions.replace(
        "DNS:api.anthropic.com,DNS:api.openai.com", "DNS:wrong.invalid"))
    openssl("x509", "-req", "-in", "leaf.csr", "-CA", "ca.pem", "-CAkey", "ca.key",
            "-CAcreateserial", "-days", "1", "-extfile", "wrong.ext", "-out", "wrong.pem")
    openssl("x509", "-req", "-in", "leaf.csr", "-signkey", "leaf.key", "-days", "1",
            "-extfile", "extensions", "-out", "self.pem")
    (work / "index").write_text("")
    (work / "serial").write_text("1000\n")
    (work / "ca.conf").write_text("""[ca]
default_ca = authority
[authority]
database = index
serial = serial
new_certs_dir = .
certificate = ca.pem
private_key = ca.key
default_md = sha256
policy = policy
[policy]
commonName = supplied
""")
    openssl("ca", "-batch", "-config", "ca.conf", "-in", "leaf.csr", "-out", "expired.pem",
            "-notext", "-extfile", "extensions", "-startdate", "200101000000Z",
            "-enddate", "200102000000Z")
    for name, source in [("forward_ca", "ca"), ("forward_leaf", "leaf"),
                         ("wrong_host", "wrong"), ("self_signed", "self"), ("expired", "expired")]:
        openssl("x509", "-in", source + ".pem", "-outform", "DER", "-out", name + ".der")
        (out / (name + ".der")).write_bytes((work / (name + ".der")).read_bytes())
    openssl("pkcs8", "-topk8", "-nocrypt", "-in", "leaf.key", "-outform", "DER",
            "-out", "forward_leaf.pkcs8.der")
    (out / "forward_leaf.pkcs8.der").write_bytes((work / "forward_leaf.pkcs8.der").read_bytes())
