#!/usr/bin/env python3
"""Read-only Mac environment observations for the iso remote-host experiment.

This does not execute iso, inspect user configuration, connect to another host,
start a service, enroll keys, create a VM, or qualify any isolation property.
Only fixed system commands with fixed options (and the numeric current UID for
launchctl's read-only print command) may run. Raw process output is not emitted.
"""

import argparse
import datetime
import json
import os
import platform
import re
import subprocess
import sys


BASELINE_COMMIT = "47d17ba2524b145b229abcf42c85f8b5f0071e65"
STAGES = (
    "workspace",
    "preparation",
    "fresh_boot_before_gui",
    "gui_logged_in",
    "gui_locked",
    "after_logout",
    "reboot_before_gui",
)


def observe(argv, retain_output=True):
    """Run one known system query, with no shell or caller environment."""
    if not os.path.isfile(argv[0]) or not os.access(argv[0], os.X_OK):
        return {"status": "missing"}, ""
    try:
        result = subprocess.run(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE if retain_output else subprocess.DEVNULL,
            stderr=subprocess.PIPE if retain_output else subprocess.DEVNULL,
            timeout=10,
            check=False,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"},
        )
    except subprocess.TimeoutExpired:
        return {"status": "timeout"}, ""
    except OSError:
        return {"status": "unavailable"}, ""
    # These fixed version/OS queries have bounded expected output. Discard raw
    # content after selecting the small fields below; never expose diagnostics.
    output = ""
    if retain_output:
        output = (result.stdout[:8192] + result.stderr[:8192]).decode(
            "utf-8", errors="replace"
        )
    return {
        "status": "observed" if result.returncode == 0 else "query_failed",
        "exit_code": result.returncode,
    }, output


def query_value(argv, pattern):
    result, raw = observe(argv)
    match = re.search(pattern, raw) if result["status"] == "observed" else None
    result["value"] = match.group(1) if match else None
    return result


def version_tuple(value):
    if not value:
        return ()
    return tuple(int(part) for part in value.split("."))


def report(stage):
    system = platform.system()
    result = {
        "schema": "iso.mac-validation.preflight/v1",
        "baseline_commit": BASELINE_COMMIT,
        "observed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "result": "unsupported_platform",
        "stage_claim": stage,
        "stage_verified": False,
        "platform": {"system": system, "process_architecture": platform.machine()},
        "python_version": platform.python_version(),
        "scope": "OS and developer-tool observations only; no network or VM actions",
        "requirements_from_baseline": {
            "host_os": "macOS 27+",
            "hardware": "Apple Silicon",
            "build_tools": "Xcode 27+, Swift 6.4+ (exact build still needs qualification)",
            "iso_sandbox_protocol": 5,
            "containerization": "0.45.0",
            "image_builder": "Apple container 1.4.1+ with its service running",
        },
        "not_tested": [
            "iso_binary_availability",
            "iso_sandbox_binary_availability_or_qualification",
            "builder_availability_or_service_readiness",
            "kernel_and_init_image_pins",
            "AppleIsolation",
            "VM_creation_or_boot",
            "headless_operation_or_reboot_recovery",
            "management_or_guest_SSH_identity",
            "guest_routing",
            "controller_disconnect_behavior",
            "host_TTL_enforcement",
        ],
    }
    if system != "Darwin":
        result["reason"] = "This source baseline supports macOS Apple Silicon hosts only."
        return result, 2

    uid = os.getuid()
    observations = {
        "macos_version": query_value(
            ["/usr/bin/sw_vers", "-productVersion"], r"^([0-9]+(?:\.[0-9]+)*)\s*$"
        ),
        "native_arm64": query_value(
            ["/usr/sbin/sysctl", "-n", "hw.optional.arm64"], r"^([01])\s*$"
        ),
        "hypervisor_hint": query_value(
            ["/usr/sbin/sysctl", "-n", "kern.hv_support"], r"^([01])\s*$"
        ),
        "boot_session_uuid": query_value(
            ["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"],
            r"^([A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12})\s*$",
        ),
        "xcode_version": query_value(
            ["/usr/bin/xcodebuild", "-version"], r"\bXcode ([0-9]+(?:\.[0-9]+)*)"
        ),
        "swift_version": query_value(
            ["/usr/bin/xcrun", "swift", "--version"],
            r"\bSwift version ([0-9]+(?:\.[0-9]+)*)",
        ),
        "ssh_client_version": query_value(
            ["/usr/bin/ssh", "-V"], r"\bOpenSSH_([0-9]+(?:\.[0-9]+)*(?:p[0-9]+)?)"
        ),
        # Domain output may include unrelated job/environment details. Discard
        # it at the OS descriptor, retaining only the query's exit status.
        "user_domain_query": observe(
            ["/bin/launchctl", "print", "user/" + str(uid)], retain_output=False
        )[0],
        "gui_domain_query": observe(
            ["/bin/launchctl", "print", "gui/" + str(uid)], retain_output=False
        )[0],
    }
    try:
        console_uid = os.stat("/dev/console").st_uid
        observations["console_owned_by_current_uid"] = console_uid == uid
    except OSError:
        observations["console_owned_by_current_uid"] = None
    result["observations"] = observations
    result["headless_evidence_note"] = (
        "A GUI-domain query or console owner is a momentary observation. "
        "Neither proves that no GUI login occurred during this boot."
    )
    macos = version_tuple(observations["macos_version"]["value"])
    arm64 = observations["native_arm64"]["value"]
    xcode = version_tuple(observations["xcode_version"]["value"])
    swift = version_tuple(observations["swift_version"]["value"])
    if macos and macos < (27,):
        result["result"] = "unsupported_os_version"
        return result, 2
    if arm64 == "0":
        result["result"] = "unsupported_hardware"
        return result, 2
    if not macos or arm64 != "1" or not xcode or not swift:
        result["result"] = "incomplete_preflight"
        return result, 3
    if xcode < (27,) or swift < (6, 4):
        result["result"] = "build_tools_below_baseline"
        return result, 2
    result["result"] = "eligible_for_live_validation"
    result["reason"] = (
        "OS, architecture and developer-tool version observations meet baseline minimums. "
        "Every runtime, identity, routing and lifecycle gate remains untested."
    )
    return result, 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", choices=STAGES, default="preparation")
    args = parser.parse_args()
    result, exit_code = report(args.stage)
    print(json.dumps(result, indent=2, sort_keys=True, allow_nan=False))
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
