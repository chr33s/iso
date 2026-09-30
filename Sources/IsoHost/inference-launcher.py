#!/usr/bin/env python3
"""iso's launcher for a managed mlx-lm backend (secure-local-inference spec §20.3).

    launcher.py --model DIR --port PORT --token-file FILE [--memory-limit BYTES]

Runs `mlx_lm.server` bound to 127.0.0.1 with a request handler that requires
`Authorization: Bearer <token>` (constant-time compare), refuses any `Origin`
header and serves no CORS. It passes no adapter, draft-model or remote-code
option, pins every model load to --model, and caps MLX memory. It refuses
mlx-lm versions it was not qualified with. Installed root-owned by `iso inference provision`; run by launchd as the
role account.
"""

import argparse
import hmac
import os
import sys

QUALIFIED = ("0.31.",)


def parse():
    parser = argparse.ArgumentParser(description="iso managed mlx-lm backend")
    parser.add_argument("--model", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--memory-limit", type=int)
    args = parser.parse_args()
    if not (1024 <= args.port <= 65535):
        parser.error("port out of range")
    if not os.path.isabs(args.model) or not os.path.isdir(args.model):
        parser.error("model must be an absolute directory")
    return args


def read_token(path):
    with open(path, "r", encoding="ascii") as handle:
        token = handle.read().strip()
    if len(token) != 64 or any(c not in "0123456789abcdef" for c in token):
        raise SystemExit("launcher: the token file must hold 64 lowercase hex digits")
    return token.encode()


def authenticating(handler_class, token):
    """Wrap every request method with the bearer check."""

    class Authenticated(handler_class):
        def _authorized(self):
            if self.headers.get("Origin") is not None:
                return False
            values = self.headers.get_all("Authorization") or []
            if len(values) != 1 or not values[0].startswith("Bearer "):
                return False
            return hmac.compare_digest(values[0][7:].encode(), token)

        def _refuse(self):
            self.send_response(401)
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True

        def _set_cors_headers(self):
            pass

        def do_POST(self):
            if not self._authorized():
                return self._refuse()
            return super().do_POST()

        def do_GET(self):
            if not self._authorized():
                return self._refuse()
            return super().do_GET()

        def do_OPTIONS(self):
            return self._refuse()

        def log_message(self, *args):
            # Request lines can carry prompt fragments; log nothing.
            pass

    return Authenticated


def main():
    args = parse()
    token = read_token(args.token_file)
    import mlx.core as mx
    import mlx_lm
    from mlx_lm import server

    if not str(getattr(mlx_lm, "__version__", "")).startswith(QUALIFIED):
        raise SystemExit(f"launcher: mlx-lm {getattr(mlx_lm, '__version__', '?')} is not qualified")

    if args.memory_limit:
        limit = args.memory_limit
        mx.set_memory_limit(limit)
        wired = mx.set_wired_limit

        def clamped_wired_limit(value):
            return wired(min(value, limit))

        mx.set_wired_limit = clamped_wired_limit

    # A request can name any model path, adapter or draft model; the
    # launcher pins every load to the model it was started with.
    load = server.ModelProvider.load

    def pinned_load(self, *_args, **_kwargs):
        return load(self, "default_model", None, "default_model")

    server.ModelProvider.load = pinned_load

    original = server._run_http_server

    def run_http_server(host, port, response_generator, *rest, **kwargs):
        kwargs["handler_class"] = authenticating(server.APIHandler, token)
        return original("127.0.0.1", port, response_generator, **kwargs)

    server._run_http_server = run_http_server
    sys.argv = [
        "mlx_lm.server", "--model", args.model, "--host", "127.0.0.1", "--port", str(args.port),
        "--log-level", "WARNING",
    ]
    server.main()


if __name__ == "__main__":
    main()
