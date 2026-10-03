#!/usr/bin/env python3
"""Run the guest admission-pressure fixture against a confined local companion."""
import argparse
import importlib.util
from pathlib import Path
import socket
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def exercise(binary):
    lease = load("lease", ROOT / "scripts/test-swift-egress-lease.py")
    pressure = load("pressure", ROOT / "tests/fixtures/credential-proxy/egress-pressure.py")
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    with tempfile.TemporaryFile() as log:
        companion = lease.Companion(binary, port, log)
        stopped = threading.Event()
        failures = []

        def renew():
            try:
                while not stopped.wait(.25):
                    companion.renew()
            except BaseException as error:
                failures.append(error)

        worker = threading.Thread(target=renew)
        try:
            companion.ready()
            worker.start()
            companion.denied_request()
            pressure.exercise(port)
            companion.denied_request()
            assert not failures, "lease renewal failed during pressure control"
        finally:
            stopped.set()
            if worker.ident is not None:
                worker.join(timeout=2)
            companion.close()
    print("PASS confined companion recovers after admission and slow-head pressure", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, help="explicit production or fault-injected companion")
    args = parser.parse_args()
    binary = args.binary
    if binary is None:
        directory = subprocess.check_output(
            ["swift", "build", "--package-path", str(ROOT / "iso-egress"), "--show-bin-path"], text=True).strip()
        binary = Path(directory) / "iso-egress"
    exercise(binary.resolve())


if __name__ == "__main__":
    main()
