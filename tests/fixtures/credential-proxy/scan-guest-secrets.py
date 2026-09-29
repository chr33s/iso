"""Scan regular guest files for synthetic credentials, without following links."""
import json
import os
from pathlib import Path
import stat
import sys
import tempfile


def scan(root, needles):
    matches = []
    files = 0
    witnessed = set()
    overlap = max(map(len, needles)) - 1
    def walk_error(error):
        raise error
    for directory, directories, names in os.walk(root, followlinks=False, onerror=walk_error):
        if directory == "/":
            directories[:] = [name for name in directories if name not in {"proc", "sys", "dev"}]
        for name in names:
            path = Path(directory) / name
            if not stat.S_ISREG(path.lstat().st_mode):
                continue
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, "rb") as source:
                assert stat.S_ISREG(os.fstat(source.fileno()).st_mode)
                files += 1
                if str(path) in {"/home/ubuntu/.codex/config.toml", "/home/ubuntu/.claude/settings.json"}:
                    witnessed.add(str(path))
                tail = b""
                found = set()
                while chunk := source.read(512 * 1024):
                    data = tail + chunk
                    found.update(index for index, needle in enumerate(needles) if needle in data)
                    tail = data[-overlap:] if overlap else b""
                if found:
                    matches.append({"path": str(path), "credential_indices": sorted(found)})
    return matches, files, witnessed


def main():
    assert sys.platform == "linux" and os.geteuid() == 0, "run only inside the Linux test guest as root"
    needles = [value.encode() for value in json.load(sys.stdin)]
    assert needles and all(needles)
    with tempfile.TemporaryDirectory(prefix="iso-secret-scan-") as directory:
        # Straddle the read boundary to prove the overlap check also works.
        canary = Path(directory) / "canary"
        canary.write_bytes(b"x" * (512 * 1024 - 3) + b"\n".join(needles))
        found, count, _ = scan(directory, needles)
        assert count == 1 and found == [{"path": str(canary), "credential_indices": list(range(len(needles)))}]
    found, count, witnessed = scan("/", needles)
    assert count > 100 and len(witnessed) == 2, "scan missed the provisioned guest configuration"
    assert not found, f"synthetic provider credential found in guest files: {found}"
    print(json.dumps({"files_scanned": count, "configuration_files": sorted(witnessed), "matches": 0,
                      "canary_detected_and_removed": True, "excluded_pseudofilesystems": ["/proc", "/sys", "/dev"]}))


if __name__ == "__main__":
    main()
