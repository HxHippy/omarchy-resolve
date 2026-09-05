#!/usr/bin/env python3
"""Route resolver.

Answers one question: given a thing to install and a machine to install it on,
what are the known ways to get it, best first?

It never installs anything and never touches the client. The client asks, this
answers, the client's plugins do the work. That boundary is the whole design:
a broken package in Debian is Debian's outage, not ours.
"""

from __future__ import annotations

import base64
import json
import os
import pathlib
import subprocess
import tempfile
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROUTES_DIR = pathlib.Path(os.environ.get("ROUTES_DIR", pathlib.Path(__file__).parent / "routes"))
LISTEN_PORT = int(os.environ.get("PORT", "8080"))

# Localhost by default. This service decides what a privileged package manager
# installs on every machine that asks, so exposing it is a deliberate act and
# should look like one in the command line rather than being the default.
LISTEN_ADDR = os.environ.get("LISTEN_ADDR", "127.0.0.1")

# ed25519 private key used to sign every answer. Clients pin the matching
# public key and discard anything that does not verify, which is what stops a
# spoofed or man-in-the-middled resolver naming any package it likes.
SIGNING_KEY = os.environ.get("SIGNING_KEY", "")

# How much the answer is worth. Ordered best first.
#
# This is a support boundary, not a quality score. "built-here" means we built
# it, signed it and serve it, so a failure is a bug report we owe someone.
# Everything below it we are pointing at somebody else's work, and a failure
# belongs upstream. The client shows this to the user; it is not decoration.
TRUST_RANK = {
    "built-here": 0,
    "distro": 1,
    "flathub": 2,
    "upstream": 3,
    "unverified": 4,
}

# Tiebreaker within a trust tier. Repology's own vocabulary, so route data
# seeded from a dump sorts without translation.
FRESHNESS_RANK = {
    "newest": 0,
    "devel": 1,
    "rolling": 2,
    "unknown": 3,
    "outdated": 4,
    "legacy": 5,
}


def load_routes() -> dict:
    """Read every route file once at startup.

    A real deployment reloads these from a database. For a prototype, failing
    loudly on a malformed file at boot beats discovering it during a resolve.
    """
    table = {}
    for path in sorted(ROUTES_DIR.glob("*.json")):
        with path.open() as handle:
            entry = json.load(handle)
        table[entry["name"]] = entry
    return table


def matches(route: dict, field: str, value: str) -> bool:
    """A route with no opinion on a field applies everywhere."""
    allowed = route.get(field)
    if not allowed:
        return True
    return value in allowed or "any" in allowed


def rank(route: dict) -> tuple:
    return (
        TRUST_RANK.get(route.get("trust", "unverified"), 99),
        FRESHNESS_RANK.get(route.get("freshness", "unknown"), 99),
    )


def resolve(table: dict, name: str, os_name: str, arch: str, variant: str | None) -> dict:
    entry = table.get(name)
    if entry is None:
        return {"name": name, "found": False, "routes": []}

    usable = []
    for route in entry["routes"]:
        if not matches(route, "os", os_name) or not matches(route, "arch", arch):
            continue
        # A variant route only appears when it was asked for. Otherwise the
        # headless build of a GUI tool would outrank the thing the user meant.
        if route.get("variant") and route["variant"] != variant:
            continue
        if variant and not route.get("variant") and any(
            r.get("variant") == variant for r in entry["routes"]
        ):
            continue
        usable.append(route)

    usable.sort(key=rank)

    return {
        "name": entry["name"],
        "summary": entry.get("summary"),
        "homepage": entry.get("homepage"),
        "found": True,
        "query": {"os": os_name, "arch": arch, "variant": variant},
        "routes": usable,
    }


def sign(body: bytes) -> str | None:
    """Sign a response body with the ed25519 key, if one is configured.

    Shells out to openssl rather than taking a dependency on a crypto library,
    because openssl is already on every machine this would ever run on and a
    prototype that needs pip install to be secure will be run insecurely.
    """
    if not SIGNING_KEY:
        return None

    with tempfile.NamedTemporaryFile() as body_file:
        body_file.write(body)
        body_file.flush()
        result = subprocess.run(
            ["openssl", "pkeyutl", "-sign", "-inkey", SIGNING_KEY,
             "-rawin", "-in", body_file.name],
            capture_output=True,
            check=False,
        )

    if result.returncode != 0:
        # Failing closed matters more than staying up: an unsigned answer from
        # a resolver that is supposed to sign is indistinguishable from an
        # attacker stripping the header.
        raise RuntimeError(f"signing failed: {result.stderr.decode().strip()}")

    return base64.b64encode(result.stdout).decode()


class Handler(BaseHTTPRequestHandler):
    table: dict = {}

    # Do not advertise the Python version to anything that connects.
    server_version = "omarchy-resolve"
    sys_version = ""

    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload, indent=2).encode()

        try:
            signature = sign(body)
        except RuntimeError as exc:
            self.log_message("%s", exc)
            body = json.dumps({"error": "signing unavailable"}).encode()
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if signature:
            self.send_header("X-Route-Signature", signature)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 - stdlib naming
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)

        if parsed.path == "/health":
            return self._send(200, {"ok": True, "packages": len(self.table)})

        if parsed.path == "/packages":
            return self._send(200, {"packages": sorted(self.table)})

        if parsed.path == "/resolve":
            name = (query.get("name") or [""])[0]
            if not name:
                return self._send(400, {"error": "name is required"})
            result = resolve(
                self.table,
                name,
                (query.get("os") or ["any"])[0],
                (query.get("arch") or ["any"])[0],
                (query.get("variant") or [None])[0],
            )
            return self._send(200 if result["found"] else 404, result)

        self._send(404, {"error": "no such endpoint"})

    def log_message(self, fmt: str, *args) -> None:
        print(f"{self.address_string()} {fmt % args}", flush=True)


def main() -> None:
    Handler.table = load_routes()
    print(f"loaded {len(Handler.table)} package(s) from {ROUTES_DIR}", flush=True)

    if SIGNING_KEY:
        # Prove the key works now rather than discovering it is wrong on the
        # first request, when the failure mode is every client refusing to act.
        sign(b"startup check")
        print(f"signing answers with {SIGNING_KEY}", flush=True)
    else:
        print("WARNING: no SIGNING_KEY set, answers will be unsigned and "
              "clients should refuse them", flush=True)

    print(f"listening on {LISTEN_ADDR}:{LISTEN_PORT}", flush=True)
    ThreadingHTTPServer((LISTEN_ADDR, LISTEN_PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
