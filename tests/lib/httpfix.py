#!/usr/bin/env python3
"""Loopback HTTP server over a fixture directory, for tests of downloads and
version adapters that use the real curl or Python's urllib.

Usage: httpfix.py ROOT [--host HOST] [--port PORT] [--port-file FILE]
                       [--log FILE]

A request for /a/b?q=1 is answered with the file ROOT/a/b?q=1 when it
exists, else ROOT/a/b. Optional sidecar files next to the answer (or next to
where it would be) change the response:
  NAME.status    the HTTP status code (the body is still served)
  NAME.headers   extra "Name: value" header lines (they replace defaults)
  NAME.delay     seconds to wait before answering
  NAME.location  a redirect target (status 302 unless NAME.status says
                 otherwise); NAME itself need not exist
Sidecar files are never served themselves, and paths with "." or ".."
segments, directories and anything outside ROOT answer 404. GET and HEAD are
supported. Every request is appended to the log file as "METHOD PATH". The
bound port is written to the port file once the server listens (use
--port 0 for a free port). tests/lib/harness.sh wraps this as
ds_httpfix_start and ds_httpfix_stop.
"""

import argparse
import mimetypes
import os
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SIDECARS = (".status", ".headers", ".delay", ".location")


def read_text(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read().strip()


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "httpfix"
    sys_version = ""

    def log_message(self, *args):
        pass

    def do_GET(self):
        self.respond(send_body=True)

    def do_HEAD(self):
        self.respond(send_body=False)

    def resolve(self):
        """Returns the base path (answer file or where it would be) or None."""
        parsed = urllib.parse.urlsplit(self.path)
        relative = urllib.parse.unquote(parsed.path)
        segments = relative.split("/")[1:]
        if not relative.startswith("/") or any(s in (".", "..") for s in segments):
            return None
        if any(relative.endswith(suffix) for suffix in SIDECARS):
            return None
        root = self.server.root
        base = os.path.join(root, *[s for s in segments if s])
        if parsed.query:
            with_query = base + "?" + parsed.query
            if os.path.lexists(with_query) or any(
                os.path.exists(with_query + suffix) for suffix in SIDECARS
            ):
                base = with_query
        real = os.path.realpath(base)
        if real != root and not real.startswith(root + os.sep):
            return None
        return base

    def respond(self, send_body):
        with self.server.log_lock:
            if self.server.log:
                self.server.log.write(f"{self.command} {self.path}\n")
                self.server.log.flush()
        base = self.resolve()
        body_path = base if base and os.path.isfile(base) else None

        def exists(suffix):
            return base is not None and os.path.isfile(base + suffix)

        if base is None or (body_path is None and not exists(".location")):
            self.send_plain(404, b"not found\n", send_body)
            return
        if exists(".delay"):
            time.sleep(float(read_text(base + ".delay")))
        status = int(read_text(base + ".status")) if exists(".status") else 200
        headers = {}
        if exists(".location"):
            if not exists(".status"):
                status = 302
            headers["Location"] = read_text(base + ".location")
        body = b""
        if body_path:
            with open(body_path, "rb") as handle:
                body = handle.read()
        content_type = mimetypes.guess_type(urllib.parse.urlsplit(self.path).path)[0]
        headers["Content-Type"] = content_type or "application/octet-stream"
        if exists(".headers"):
            with open(base + ".headers", encoding="utf-8") as handle:
                for line in handle:
                    name, sep, value = line.rstrip("\r\n").partition(":")
                    if sep and name.strip():
                        headers[name.strip()] = value.strip()
        self.send_response(status)
        for name, value in headers.items():
            if name.lower() != "content-length":
                self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if send_body:
            self.wfile.write(body)

    def send_plain(self, status, body, send_body):
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if send_body:
            self.wfile.write(body)


def main(argv):
    parser = argparse.ArgumentParser(description="Serve a fixture directory over loopback HTTP.")
    parser.add_argument("root", help="directory to serve")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--port-file", help="file that receives the bound port")
    parser.add_argument("--log", help="file that receives one line per request")
    args = parser.parse_args(argv)
    if not os.path.isdir(args.root):
        parser.error(f"no such directory: {args.root}")

    server = ThreadingHTTPServer((args.host, args.port), FixtureHandler)
    server.daemon_threads = True
    server.root = os.path.realpath(args.root)
    server.log_lock = threading.Lock()
    server.log = open(args.log, "a", encoding="utf-8") if args.log else None
    if args.port_file:
        temporary = args.port_file + ".tmp"
        with open(temporary, "w", encoding="utf-8") as handle:
            handle.write(f"{server.server_address[1]}\n")
        os.replace(temporary, args.port_file)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
