#!/usr/bin/env python3
"""The OpenCode /skill API probe of the opencode-pi component.

Usage: opencode-skill-api.py

Starts `opencode serve --pure` on a free loopback port, waits up to 20
seconds for GET /skill, and prints the sorted JSON array of the names of the
skills OpenCode lists. OpenCode reads several skill roots and lists a name
found in more than one SKILL.md once, from whichever root it loaded last,
so a name counts whatever location OpenCode chose; skill-shadows.py names
the other files of an expected name. The server is always stopped (SIGTERM,
then SIGKILL after 5 seconds). On failure it prints "OpenCode skill catalog
could not be verified: <reason>" and the tail of the server output to
standard error and exits 1. Proxies are bypassed: the server is local.
"""

from __future__ import annotations

import json
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

STARTUP_SECONDS = 20
STOP_SECONDS = 5
LOG_TAIL = 2000


def free_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def fetch_skills(port: int, server: subprocess.Popen[str]) -> object:
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    deadline = time.monotonic() + STARTUP_SECONDS
    while True:
        if server.poll() is not None:
            raise RuntimeError(f"the OpenCode server exited early (exit {server.returncode})")
        try:
            with opener.open(f"http://127.0.0.1:{port}/skill", timeout=2) as response:
                return json.load(response)
        except (OSError, ValueError):
            if time.monotonic() >= deadline:
                raise RuntimeError(f"GET /skill did not answer within {STARTUP_SECONDS} seconds") from None
            time.sleep(0.25)


def stop(server: subprocess.Popen[str]) -> None:
    if server.poll() is not None:
        return
    server.terminate()
    try:
        server.wait(timeout=STOP_SECONDS)
    except subprocess.TimeoutExpired:
        server.kill()
        server.wait()


def listed_names(skills: object) -> list[str]:
    """The sorted names of the skills of a GET /skill answer."""
    if not isinstance(skills, list):
        raise RuntimeError("GET /skill did not answer a list")
    return sorted({item["name"] for item in skills if isinstance(item, dict) and isinstance(item.get("name"), str)})


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: opencode-skill-api.py", file=sys.stderr)
        return 2
    port = free_port()
    with tempfile.TemporaryFile(mode="w+t") as log:
        server = subprocess.Popen(
            ["opencode", "serve", "--pure", "--hostname", "127.0.0.1", "--port", str(port)],
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=log,
            text=True,
        )
        try:
            names = listed_names(fetch_skills(port, server))
        except Exception as error:  # every failure is reported the same way
            stop(server)
            log.seek(0)
            output = log.read()[-LOG_TAIL:]
            print(f"[dotsteward] ERROR: OpenCode skill catalog could not be verified: {error}", file=sys.stderr)
            if output:
                print(output, file=sys.stderr, end="" if output.endswith("\n") else "\n")
            return 1
        finally:
            stop(server)
    print(json.dumps(names))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
