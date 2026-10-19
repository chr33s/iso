#!/usr/bin/env python3
"""Write one credential from the checkout's gitignored `.env` to stdout, for a
live gate's stdin or `cmd:` reference. Prints nothing else and no newline.

    python3 -I scripts/env-credential.py ANTHROPIC_API_KEY | python3 scripts/test-proxy-live.py ...
"""
import sys
from pathlib import Path

ENV = Path(__file__).resolve().parents[1] / ".env"


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: env-credential.py NAME")
    for line in ENV.read_text().splitlines():
        name, sep, value = line.partition("=")
        if sep and name.strip() == sys.argv[1]:
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
                value = value[1:-1]
            if not value:
                break
            sys.stdout.write(value)
            return
    sys.exit(f"{sys.argv[1]} is not set in {ENV.name}")


if __name__ == "__main__":
    main()
