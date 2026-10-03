"""Filtered-VM network qualification with reachable controls and owned peers."""
import ipaddress
import json
from pathlib import Path
import secrets
import socket
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[1]


def host_service_gateway(record, interface):
    index = record["subnetIndex"]
    assert type(index) is int and 0 <= index <= 255, "invalid owned subnet"
    assert record["network"] == "host_only", "host probe requires the filtered VM's owned subnet"
    subnet = ipaddress.IPv4Network(f"10.231.{index}.0/24")
    address = next(item for item in interface["addr_info"] if item["family"] == "inet")
    observed = ipaddress.IPv4Interface(f'{address["local"]}/{address["prefixlen"]}')
    assert observed.network == subnet, "guest subnet disagrees with host-owned runtime record"
    return str(subnet.network_address + 1)


def measure_host_service(guest, gateway):
    """Measure guest→host separately; host services are not the peer boundary."""
    gateway = str(ipaddress.IPv4Address(gateway))
    nonce = secrets.token_hex(16).encode()
    stopped = threading.Event()
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        # Bind only the owned VM's host-side address, not all host interfaces.
        listener.bind((gateway, 0))
        listener.listen(3)
        listener.settimeout(.2)
        port = listener.getsockname()[1]

        def serve():
            while not stopped.is_set():
                try:
                    connection, _ = listener.accept()
                except socket.timeout:
                    continue
                with connection:
                    connection.settimeout(1)
                    try:
                        connection.sendall(nonce)
                    except OSError:
                        pass

        worker = threading.Thread(target=serve)
        worker.start()

        def positive_control():
            with socket.create_connection((gateway, port), timeout=2) as connection:
                observed = b""
                while len(observed) < len(nonce):
                    chunk = connection.recv(len(nonce) - len(observed))
                    assert chunk, "host-service control closed before its nonce"
                    observed += chunk
                assert observed == nonce, "host-service positive control mismatch"

        try:
            positive_control()
            code = '''import json, socket, sys
host, port, nonce = json.load(sys.stdin)
try:
    with socket.create_connection((host, port), timeout=2) as connection:
        observed = b""
        while len(observed) < len(nonce):
            chunk = connection.recv(len(nonce) - len(observed))
            if not chunk: break
            observed += chunk
    result = {"reachable": observed.decode("ascii", errors="replace") == nonce}
except OSError as error:
    result = {"reachable": False, "error": type(error).__name__}
print(json.dumps(result))
'''
            output = guest("brokers", "python3", "-c", code,
                           input=json.dumps([gateway, port, nonce.decode()]), timeout=8)
            observation = json.JSONDecoder().raw_decode(output)[0]
            assert type(observation.get("reachable")) is bool, "missing host-service measurement"
            positive_control()
            print("MEASURE filtered guest to host TCP service", json.dumps(observation), flush=True)
        finally:
            stopped.set()
            worker.join(timeout=2)
            assert not worker.is_alive(), "host-service fixture failed to stop"


def exercise(work, config, run):
    original = config.read_text()
    settings = json.loads(original)
    project = work / "network-control-project"
    project.mkdir()

    def write(value):
        config.write_text(json.dumps(value))

    def guest(instance, *args, **kwargs):
        command = "shell" if "input" in kwargs else "exec"
        return run([command, instance, "--", *args], **kwargs)[0]

    try:
        control = {**settings, "egress": "open", "proxy": {"mode": "off"}}
        control.pop("egress_filter", None)
        control.pop("post_start", None)
        write(control)
        run(["up", str(project), "--name", "network-control", "--no-agents", "--no-github", "--no-devcontainer"])
        # Prove the exact direct-IP probe works before treating its refusal as
        # isolation evidence. No provider operation or credential is involved.
        guest("network-control", "timeout", "5", "bash", "-c", "exec 3<>/dev/tcp/1.1.1.1/443")
        guest("network-control", "curl", "--noproxy", "*", "--fail", "--silent", "--show-error",
              "--max-time", "20", "--output", "/dev/null", "https://api.github.com")
        addresses = guest("network-control", "ip", "-j", "address", "show", "eth0", private=True)
        # stdout precedes CLI diagnostics; decode only its leading JSON value.
        interface = json.JSONDecoder().raw_decode(addresses)[0][0]
        ipv4 = next(item["local"] for item in interface["addr_info"] if item["family"] == "inet")
        ipv6 = next(item["local"] for item in interface["addr_info"]
                    if item["family"] == "inet6" and item["scope"] == "global")
        link_local = next(item["local"] for item in interface["addr_info"]
                          if item["family"] == "inet6" and item["scope"] == "link")
        ipaddress.IPv4Address(ipv4)
        ipaddress.IPv6Address(ipv6)
        ipaddress.IPv6Address(link_local)
        guest("network-control", "sudo", "bash", "-c",
              'sysctl -qw net.ipv4.icmp_echo_ignore_broadcasts=0; '
              'systemd-run --quiet --unit=iso-test-tcp socat TCP6-LISTEN:7777,ipv6only=0,fork,reuseaddr SYSTEM:"echo pong"; '
              'systemd-run --quiet --unit=iso-test-udp socat UDP6-RECVFROM:7778,ipv6only=0,fork SYSTEM:"echo upong"')
        guest("network-control", "bash", "-c",
              'for attempt in {1..50}; do '
              'if timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/7777"; then exit 0; fi; '
              'sleep .1; done; exit 1')
        write(settings)
        fixtures = ROOT / "tests/fixtures/apple-sandbox"

        guest("brokers", "bash", "-c",
              'if timeout 5 bash -c "exec 3<>/dev/tcp/1.1.1.1/443"; then exit 1; fi')
        guest("brokers", "true")
        print("PASS direct Internet TCP refused under filtered mode; open VM control succeeds and management SSH survives", flush=True)

        # Exercise production confined DNS/connect and real TLS with an explicit
        # approved destination, without adding any release-only policy bypass.
        run(["stop", "brokers"])
        approved = {**settings, "egress_filter": {"allowed_hosts": ["api.github.com"]}}
        write(approved)
        run(["start", "brokers", "--no-github"])
        guest("brokers", "curl", "--fail", "--silent", "--show-error", "--max-time", "20",
              "--output", "/dev/null", "https://api.github.com")
        guest("brokers", "bash", "-c",
              'code=$(curl --silent --output /dev/null --max-time 8 --write-out "%{http_connect}" https://example.com); '
              '[ "$?" -eq 56 ] && [ "$code" = 403 ]')
        print("PASS approved HTTPS succeeds with TLS verification; unapproved CONNECT is denied", flush=True)

        filtered_addresses = guest("brokers", "ip", "-j", "-4", "address", "show", "eth0", private=True)
        filtered_interface = json.JSONDecoder().raw_decode(filtered_addresses)[0][0]
        backend = work / "data/backends/apple-container-v1"
        machine = json.loads((backend / "instances/brokers/apple-machine.json").read_text())["machine_id"]
        record = json.loads((backend / "runtime/sandboxes" / machine / "record.json").read_text())
        assert record["id"] == machine, "runtime record belongs to a different VM"
        measure_host_service(guest, host_service_gateway(record, filtered_interface))

        def host_controls(wait_seconds=0):
            # IPv4 UDP/ICMP replies do not reach host sockets on this platform;
            # preserve the existing runtime suite's explicit control limitation.
            required = ("ipv4-tcp", "ipv6-tcp", "ipv6-udp", "ipv6-icmp")
            deadline = time.monotonic() + wait_seconds
            while True:
                result = subprocess.run([str(fixtures / "host-probe.sh"), ipv4, ipv6],
                                        capture_output=True, text=True, timeout=30, check=True)
                observed = json.loads(result.stdout)
                failed = [key for key in required if observed.get(key) is not True]
                print("host peer controls", json.dumps({key: observed.get(key) for key in required}), flush=True)
                if not failed or time.monotonic() >= deadline:
                    break
                time.sleep(1)
            if failed:
                # Numeric addresses come from the owned control VM and have
                # already passed ipaddress parsing; no shell interpolation.
                subprocess.run(["/sbin/route", "-n", "get", "-inet6", ipv6], timeout=5)
                subprocess.run(["/sbin/route", "-n", "get", ipv4], timeout=5)
                print("control addresses", ipv4, ipv6, flush=True)
            assert not failed, "peer positive control unreachable: " + ", ".join(failed)

        # Allow host IPv6 address/route initialization to finish after VM boot.
        # Missing reachability still fails; it never counts as isolation.
        host_controls(wait_seconds=60)
        probes = guest("brokers", "sudo", "env", "ISO_REQUIRE_INJECTION=1", "bash", "-s", "--", ipv4, ipv6, interface["address"], link_local,
                       input=(fixtures / "peer-probe.sh").read_text(), timeout=150)
        observations = [json.loads(line) for line in probes.splitlines() if line.startswith('{"probe":')]
        required = {
            "ipv4-tcp", "ipv4-udp", "ipv4-icmp", "ipv6-tcp", "ipv6-udp", "ipv6-icmp",
            "ipv4-onlink-route-tcp", "ipv4-onlink-route-icmp", "ipv6-onlink-route-tcp",
            "ipv4-static-neigh-tcp", "ipv6-static-neigh-tcp",
            "ipv4-spoofed-src-tcp", "ipv4-spoofed-src-icmp", "ipv6-allnodes-multicast",
            "ipv4-bcast-mcast:255.255.255.255", "ipv4-bcast-mcast:224.0.0.1",
            "ipv4-bcast-mcast:" + ipv4.rsplit(".", 1)[0] + ".255",
        }
        assert required <= {item["probe"] for item in observations}, "incomplete adversarial network probes"
        assert all(item["reached"] is False for item in observations), "filtered guest reached peer"
        host_controls()
        print("PASS filtered peer isolation: IPv4/IPv6, forged routes/neighbours, source spoofing and multicast; host controls before/after", flush=True)

    finally:
        # A changed config does not retroactively change a running boot policy.
        # Stop needs no guest handoff and restores that symmetry before cleanup.
        run(["stop", "brokers"])
        config.write_text(original)
        run(["destroy", "network-control"])
