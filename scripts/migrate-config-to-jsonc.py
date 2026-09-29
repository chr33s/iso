#!/usr/bin/env python3
"""Convert a iso config.toml to config.jsonc, offline and once.

    python3 scripts/migrate-config-to-jsonc.py --input ~/.iso/config.toml \
        --output ~/.iso/config.jsonc [--drop-retired-fields]

Requires Python 3.11+ (standard-library ``tomllib``). The script reads only
the input file: it never executes ``cmd:`` values, contacts a provider, or
reads credentials. The source is left untouched and an existing destination
(including a symlink) is refused. The result is written with mode 0600 and
only after it has been re-read and compared with the converted value.

Retired Firecracker host settings (``firecracker_bin``, ``vm.kernel_path``,
``vm.boot_args``, ``network.*``) are refused unless ``--drop-retired-fields``
is given. Literal provider proxy credentials are always refused: store them
with ``iso proxy setup`` (macOS Keychain) or write a ``cmd:`` reference.
Diagnostics name field paths only, never values.
"""

import argparse
import datetime
import json
import math
import os
import sys

if sys.version_info < (3, 11):
    sys.exit(
        "migrate-config-to-jsonc.py requires Python 3.11 or newer (for tomllib); "
        f"this is Python {sys.version_info.major}.{sys.version_info.minor}"
    )

import tomllib  # noqa: E402

INT64_MIN = -(2**63)
INT64_MAX = 2**63 - 1
RETIRED_TOP = ("firecracker_bin",)
RETIRED_VM = ("kernel_path", "boot_args")
RETIRED_NETWORK = ("host_ip", "subnet_mask", "host_iface")
PROXY_PROVIDERS = ("anthropic", "openai")


class ConversionError(Exception):
    pass


def render_path(path):
    out = ""
    for part in path:
        if isinstance(part, int):
            out += f"[{part}]"
        elif part and all(c.isascii() and (c.isalnum() or c in "_-") for c in part):
            out += part if not out else f".{part}"
        else:
            out += f"[{json.dumps(part, ensure_ascii=False)}]"
    return out or "<root>"


def convert_value(value, path):
    """TOML value -> JSON-compatible value, refusing anything lossy."""
    # bool before int: bool is an int subclass.
    if isinstance(value, bool) or isinstance(value, str):
        return value
    if isinstance(value, int):
        if not INT64_MIN <= value <= INT64_MAX:
            raise ConversionError(f"{render_path(path)}: integer out of 64-bit range")
        return value
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ConversionError(f"{render_path(path)}: non-finite numbers have no JSON form")
        return value
    if isinstance(value, (datetime.datetime, datetime.date, datetime.time)):
        raise ConversionError(
            f"{render_path(path)}: TOML date/time values have no JSONC mapping; "
            "rewrite the value as a string"
        )
    if isinstance(value, dict):
        return {key: convert_value(item, path + [key]) for key, item in value.items()}
    if isinstance(value, list):
        return [convert_value(item, path + [index]) for index, item in enumerate(value)]
    raise ConversionError(f"{render_path(path)}: unsupported value type")


def retired_paths(doc):
    found = [name for name in RETIRED_TOP if name in doc]
    vm = doc.get("vm")
    if isinstance(vm, dict):
        found += [f"vm.{name}" for name in RETIRED_VM if name in vm]
    if "network" in doc:
        network = doc["network"]
        if isinstance(network, dict) and network:
            found += [f"network.{name}" for name in network]
        else:
            found.append("network")
    return found


def drop_retired(doc):
    """Remove only the closed retired list; unknown network children refuse."""
    removed = []
    network = doc.get("network")
    if "network" in doc:
        if not isinstance(network, dict):
            raise ConversionError("network: expected a table; not removed")
        unknown = [name for name in network if name not in RETIRED_NETWORK]
        if unknown:
            paths = ", ".join(render_path(["network", name]) for name in unknown)
            raise ConversionError(
                f"network contains fields outside the retired list ({paths}); "
                "remove or move them by hand"
            )
        removed += [f"network.{name}" for name in network]
        del doc["network"]
        if not network:
            removed.append("network")
    for name in RETIRED_TOP:
        if name in doc:
            del doc[name]
            removed.append(name)
    vm = doc.get("vm")
    if isinstance(vm, dict):
        for name in RETIRED_VM:
            if name in vm:
                del vm[name]
                removed.append(f"vm.{name}")
    return removed


def literal_credentials(doc):
    proxy = doc.get("proxy")
    if not isinstance(proxy, dict):
        return []
    found = []
    for provider in PROXY_PROVIDERS:
        entry = proxy.get(provider)
        if isinstance(entry, dict) and "credential" in entry:
            credential = entry["credential"]
            if not (isinstance(credential, str) and credential.startswith("cmd:")):
                found.append(f"proxy.{provider}.credential")
    return found


def convert(input_path, drop_retired_fields):
    with open(input_path, "rb") as handle:
        try:
            source = tomllib.load(handle)
        except tomllib.TOMLDecodeError as error:
            # tomllib messages carry a position, not document content.
            raise ConversionError(f"not valid TOML: {error}") from None
        except UnicodeDecodeError:
            raise ConversionError("not valid UTF-8") from None
    doc = convert_value(source, [])
    retired = retired_paths(doc)
    removed = []
    if retired and not drop_retired_fields:
        raise ConversionError(
            "retired Firecracker host settings present: "
            + ", ".join(retired)
            + "\nRe-run with --drop-retired-fields to remove them (they have no effect "
            "on the Apple backend)."
        )
    if retired:
        removed = drop_retired(doc)
    literals = literal_credentials(doc)
    if literals:
        raise ConversionError(
            "literal proxy credentials are no longer accepted: "
            + ", ".join(literals)
            + "\nStore the credential with `iso proxy setup` (macOS Keychain), or replace "
            "the value with a `cmd:` reference to a command that prints it, then re-run."
        )
    return doc, removed


def publish(output_path, text):
    """Write `text` to a new file; never replace an existing entry."""
    directory = os.path.dirname(os.path.abspath(output_path))
    if os.path.lexists(output_path):
        raise ConversionError(f"{output_path} already exists; choose another --output")
    temporary = os.path.join(
        directory, f".{os.path.basename(output_path)}.{os.getpid()}.migrate.tmp"
    )
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        try:
            # link(2) refuses any existing entry, including a dangling symlink.
            os.link(temporary, output_path)
        except FileExistsError:
            raise ConversionError(f"{output_path} already exists; choose another --output") from None
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Convert a iso config.toml to config.jsonc (offline, one-time)."
    )
    parser.add_argument("--input", required=True, help="existing TOML configuration")
    parser.add_argument("--output", required=True, help="new .jsonc (or .json) file")
    parser.add_argument(
        "--drop-retired-fields",
        action="store_true",
        help="remove retired Firecracker host settings instead of refusing",
    )
    args = parser.parse_args(argv)
    if os.path.splitext(args.output)[1] not in (".jsonc", ".json"):
        print("error: --output must end in .jsonc or .json", file=sys.stderr)
        return 2
    try:
        doc, removed = convert(args.input, args.drop_retired_fields)
        text = json.dumps(doc, indent=2, ensure_ascii=False, allow_nan=False) + "\n"
        if json.loads(text) != doc:
            raise ConversionError("converted document did not round-trip; nothing written")
        publish(args.output, text)
    except ConversionError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except OSError as error:
        print(f"error: {error.strerror}: {error.filename}", file=sys.stderr)
        return 1
    for path in removed:
        print(f"removed retired field: {path}", file=sys.stderr)
    print(f"wrote {args.output}; {args.input} was not modified", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
