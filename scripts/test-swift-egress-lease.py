#!/usr/bin/env python3
"""Exercise the production companion's fd-3 pipe under its unchanged Seatbelt profile.

Uses synthetic capabilities and denied CONNECTs only: no public connection or VM.
Build iso-egress first. This checks renewal, EOF, expiry and guest-socket teardown.
"""
import base64
from contextlib import ExitStack
import fcntl
import json
import hashlib
import os
import secrets
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
PROFILE = ROOT / 'Sources/IsoHost/seatbelt-egress.sb'
CAPABILITY = 'lease-fixture-not-a-provider-credential'


def high_fd(descriptor):
    """Keep spawn sources away from the destination descriptors 0, 1, 2, 3."""
    return fcntl.fcntl(descriptor, fcntl.F_DUPFD_CLOEXEC, 10)


def control_pipe():
    read, write = os.pipe()
    copies = []
    try:
        copies.append(high_fd(read))
        copies.append(high_fd(write))
        return copies[0], copies[1]
    except BaseException:
        for descriptor in copies:
            os.close(descriptor)
        raise
    finally:
        os.close(read)
        os.close(write)


class Companion:
    def __init__(self, binary, port, log, readiness=None):
        self.pid = None
        self.status = None
        self.control = None
        self.port = port
        try:
            with ExitStack() as sources:
                read, self.control = control_pipe()
                sources.callback(os.close, read)
                startup_read, startup_write = control_pipe()
                sources.callback(os.close, startup_read)
                sources.callback(os.close, startup_write)
                stderr = high_fd(log.fileno())
                sources.callback(os.close, stderr)
                null = sources.enter_context(open(os.devnull, 'wb'))
                stdout = high_fd(null.fileno())
                sources.callback(os.close, stdout)
                command = ['/usr/bin/sandbox-exec', '-D', f'EGRESS_BIN={binary}',
                           '-f', str(PROFILE), str(binary)]
                actions = [(os.POSIX_SPAWN_DUP2, source, destination) for source, destination
                           in ((startup_read, 0), (stdout, 1), (stderr, 2), (read, 3))]
                self.pid = os.posix_spawn(command[0], command, {}, file_actions=actions)
                settings = {'listen': f'127.0.0.1:{port}', 'capability': CAPABILITY,
                            'allowedHosts': ['example.com']}
                if readiness is not None:
                    settings['readiness'] = readiness
                startup = json.dumps(settings).encode()
                assert os.write(startup_write, startup) == len(startup)
        except BaseException:
            self.close()
            raise

    def poll(self):
        if self.pid is not None and self.status is None:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.status = os.waitstatus_to_exitcode(status)
        return self.status

    def renew(self):
        assert self.poll() is None, f'companion exited early: {self.status}'
        assert os.write(self.control, b'\x01') == 1

    def connect(self):
        return socket.create_connection(('127.0.0.1', self.port), timeout=0.2)

    def ready(self):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            self.renew()
            try:
                with self.connect():
                    return
            except (ConnectionRefusedError, TimeoutError):
                time.sleep(0.05)
        raise AssertionError('companion did not listen within five seconds')

    def denied_request(self):
        auth = base64.b64encode(f'iso:{CAPABILITY}'.encode()).decode()
        with self.connect() as client:
            client.settimeout(1)
            client.sendall(('CONNECT denied.invalid:443 HTTP/1.1\r\n'
                            f'Proxy-Authorization: Basic {auth}\r\n\r\n').encode())
            response = b''
            while True:
                block = client.recv(4096)
                if not block:
                    break
                response += block
                assert len(response) < 8192
        assert response == (b'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n'
                            b'Connection: close\r\n\r\n'), response
        assert CAPABILITY.encode() not in response

    def close_control(self):
        if self.control is not None:
            os.close(self.control)
            self.control = None

    def wait(self, timeout, pending_head):
        deadline = time.monotonic() + timeout
        next_fragment = time.monotonic()
        while self.poll() is None:
            now = time.monotonic()
            assert now < deadline, 'companion did not revoke the lease'
            # Keep the unfinished head progressing so its own inactivity
            # timeout cannot masquerade as lease-driven guest teardown.
            if pending_head is not None and now >= next_fragment:
                try:
                    pending_head.sendall(b'x')
                except (BrokenPipeError, ConnectionResetError):
                    pending_head = None
                next_fragment = now + 0.15
            time.sleep(0.02)
        assert self.status == 0, f'companion exited with {self.status}'

    def close(self):
        self.close_control()
        if self.pid is not None and self.poll() is None:
            os.kill(self.pid, signal.SIGTERM)
            deadline = time.monotonic() + 2
            while self.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            if self.poll() is None:
                os.kill(self.pid, signal.SIGKILL)
                _, status = os.waitpid(self.pid, 0)
                self.status = os.waitstatus_to_exitcode(status)


def exercise(binary, eof):
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    with tempfile.TemporaryFile() as log:
        process = None
        try:
            process = Companion(binary, port, log)
            process.ready()
            # The original recv(pipe) bug exits on the first renewal. Keeping
            # the real executable alive beyond its initial grace catches it.
            until = time.monotonic() + 3.2
            requests = 0
            while time.monotonic() < until:
                process.renew()
                process.denied_request()
                requests += 1
                time.sleep(0.15)
            assert requests > 2
            with process.connect() as pending_head:
                pending_head.settimeout(3.5)
                pending_head.sendall(b'CONNECT ')
                started = time.monotonic()
                if eof:
                    process.close_control()
                process.wait(1 if eof else 3.5, pending_head)
                elapsed = time.monotonic() - started
                try:
                    assert pending_head.recv(1) == b'', 'guest socket survived revocation'
                except ConnectionResetError:
                    pass
                if not eof:
                    assert 1.3 <= elapsed <= 3.5, f'expiry elapsed {elapsed:.3f}s'
            try:
                with process.connect():
                    raise AssertionError('listener survived revocation')
            except ConnectionRefusedError:
                pass
            print(f'PASS confined pipe {"EOF" if eof else "expiry"}: '
                  f'{requests} denials served, revoke {elapsed:.3f}s, guest socket closed', flush=True)
        except BaseException:
            log.seek(0)
            text = log.read(16384).decode(errors='replace')
            assert CAPABILITY not in text, 'capability appeared in process log'
            print(text, flush=True)
            raise
        finally:
            if process is not None:
                process.close()


def exercise_readiness(binary, verifier):
    """Independent authenticated-wire check against the actual confined executable."""
    # OpenSSL 3.6.5 independently derived this public key for the synthetic seed.
    # CryptoKit may randomize signatures, so verify instead of comparing bytes.
    key = 'b' * 64
    public = bytes.fromhex('7d59c5623dd40a74aa4d5a32ac645d3b3f95daeae4c22be25476dd6a486f7382')
    boot = secrets.token_hex(16)
    identity = {'version': 2, 'privateKeyHex': key, 'bootID': boot}
    policy = 'sha256:' + hashlib.sha256(
        b'mode=filtered\nhosts=example.com\nport=443\n').hexdigest()
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    with tempfile.TemporaryFile() as log:
        process = Companion(binary, port, log, readiness=identity)
        try:
            process.ready()
            authorization = base64.b64encode(f'iso:{CAPABILITY}'.encode()).decode()
            previous = None
            for _ in range(2):
                nonce = secrets.token_hex(16)
                head = ('GET /__iso/egress-ready HTTP/1.1\r\n'
                        f'Proxy-Authorization: Basic {authorization}\r\n'
                        f'X-Iso-Nonce: {nonce}\r\n\r\n').encode()
                process.renew()
                with process.connect() as client:
                    client.settimeout(1)
                    client.sendall(head)
                    response = b''
                    while True:
                        part = client.recv(1025)
                        if not part:
                            break
                        response += part
                        assert len(response) <= 1024
                headers, body = response.split(b'\r\n\r\n', 1)
                assert headers == (b'HTTP/1.1 200 OK\r\nContent-Length: ' +
                                   str(len(body)).encode() + b'\r\nConnection: close')
                reply = json.loads(body)
                assert (reply['version'], reply['nonce'], reply['bootID'], reply['policyHash']) == (
                    2, nonce, boot, policy)
                message = f'iso-egress-readiness-v2\n{nonce}\n{boot}\n{policy}\n'
                fixture = {'publicKey': base64.b64encode(public).decode(),
                           'message': message, 'signature': reply['signature']}
                checked = subprocess.run([str(verifier)], input=json.dumps(fixture).encode(),
                                         capture_output=True, timeout=5, env={})
                assert checked.returncode == 0, 'companion signature did not verify'
                fixture['signature'] = base64.b64encode(bytes(64)).decode()
                broken = subprocess.run([str(verifier)], input=json.dumps(fixture).encode(),
                                        capture_output=True, timeout=5, env={})
                assert broken.returncode != 0, 'fixture verifier accepted an invalid signature'
                assert key.encode() not in response and CAPABILITY.encode() not in response
                if previous is not None:
                    assert previous['nonce'] != nonce
                    assert previous['signature'] != reply['signature']
                previous = reply
            for malformed in (
                head.replace(authorization.encode(), b'wrong'),
                head.replace(nonce.encode(), b'invalid'),
                head.replace(b'\r\n\r\n', b'\r\nContent-Length: 1\r\n\r\n'),
            ):
                process.renew()
                with process.connect() as client:
                    client.settimeout(1)
                    client.sendall(malformed)
                    response = b''
                    while True:
                        part = client.recv(1025)
                        if not part:
                            break
                        response += part
                        assert len(response) <= 1024
                assert response == (b'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n'
                                    b'Connection: close\r\n\r\n')
            log.seek(0)
            text = log.read(16384).decode(errors='replace')
            assert key not in text and CAPABILITY not in text
            print('PASS confined readiness: fresh authenticated boot/policy challenges, '
                  'malformed and unauthorized probes denied; no upstream request', flush=True)
        finally:
            process.close()


def main():
    binary = Path(subprocess.check_output(
        ['swift', 'build', '--package-path', str(ROOT / 'iso-egress'), '--show-bin-path'],
        text=True).strip()) / 'iso-egress'
    with tempfile.TemporaryDirectory(prefix='iso-egress-verifier-') as directory:
        verifier = Path(directory) / 'verify'
        sdk = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'],
                                      text=True).strip()
        subprocess.run(['swiftc', '-sdk', sdk, str(ROOT / 'scripts/verify-egress-readiness.swift'),
                        '-o', str(verifier)], check=True, timeout=120)
        exercise_readiness(binary, verifier)
    exercise(binary, eof=True)
    exercise(binary, eof=False)


if __name__ == '__main__':
    main()
