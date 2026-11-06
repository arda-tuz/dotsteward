#!/usr/bin/env python3
"""Loopback smart HTTP server over `git http-backend`, for tests of what git
does when a push or a read breaks over HTTP: unlike SSH, a POST that breaks
ends `git push` with status 1.

Usage: githttp.py ROOT PLAN_FILE PORT_FILE LOG_FILE

The repositories under ROOT (symbolic links are fine) are served, receive-pack
included. The bound port is written to PORT_FILE once the server listens, and
every request is appended to LOG_FILE as "METHOD PATH". PLAN_FILE, when it
exists, holds one line "FAILURE REF"; the next POST to git-receive-pack that
names REF removes the file and fails:
  post-502    HTTP 502 before receive-pack runs: the push did not land
  post-reset  the connection is reset before receive-pack runs
  lost-502    receive-pack runs (the push landed), then HTTP 502
  lost-reset  receive-pack runs (the push landed), then the connection is reset
A reset takes the POST that curl makes again by itself on a fresh connection
too, so that git sees it. Or "FAILURE ." for the next reference advertisement,
of any repository:
  get-503     HTTP 503
  get-403     HTTP 403
"""

import http.server
import os
import socket
import struct
import subprocess
import sys

ROOT, PLAN_FILE, PORT_FILE, LOG_FILE = sys.argv[1:5]


def planned_failure():
    """The planned (FAILURE, REF), or (None, None) without a plan."""
    try:
        with open(PLAN_FILE, encoding="ascii") as plan:
            failure, ref = plan.read().split()
    except OSError:
        return None, None
    return failure, ref


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):  # noqa: A002 - the base class names it format
        pass

    def log_request(self, code="-", size="-"):
        with open(LOG_FILE, "a", encoding="ascii") as log:
            log.write(f"{self.command} {self.path}\n")

    def backend(self, body):
        """The status, headers and body that `git http-backend` answers."""
        path, _, query = self.path.partition("?")
        env = dict(
            os.environ,
            GIT_PROJECT_ROOT=ROOT,
            GIT_HTTP_EXPORT_ALL="1",
            REMOTE_USER="example-user",
            PATH_INFO=path,
            QUERY_STRING=query,
            REQUEST_METHOD=self.command,
            CONTENT_TYPE=self.headers.get("Content-Type", ""),
            HTTP_CONTENT_ENCODING=self.headers.get("Content-Encoding", ""),
            CONTENT_LENGTH=str(len(body)),
        )
        answer = subprocess.run(["git", "http-backend"], input=body, stdout=subprocess.PIPE, env=env, check=False)
        head, _, rest = answer.stdout.partition(b"\r\n\r\n")
        status = 200
        headers = []
        for line in head.split(b"\r\n"):
            name, _, value = line.partition(b": ")
            if name.lower() == b"status":
                status = int(value.split()[0])
            else:
                headers.append((name.decode(), value.decode()))
        return status, headers, rest

    def reply(self, status, headers=(), body=b""):
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def reset(self):
        self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        self.close_connection = True
        self.connection.close()

    def request_body(self):
        if self.headers.get("Transfer-Encoding", "").lower() != "chunked":
            return self.rfile.read(int(self.headers.get("Content-Length") or 0))
        body = b""
        while size := int(self.rfile.readline().strip(), 16):
            body += self.rfile.read(size)
            self.rfile.readline()
        self.rfile.readline()
        return body

    def do_GET(self):
        failure, _ = planned_failure()
        if failure in ("get-503", "get-403") and "/info/refs" in self.path:
            os.unlink(PLAN_FILE)
            self.reply(int(failure[4:]))
            return
        self.reply(*self.backend(b""))

    def do_POST(self):
        body = self.request_body()
        failure, ref = planned_failure()
        if not (self.path.endswith("git-receive-pack") and ref and ref.encode() in body[:4096]):
            failure = None
        if failure:
            os.unlink(PLAN_FILE)
        if failure in ("post-reset", "lost-reset"):
            with open(PLAN_FILE, "w", encoding="ascii") as plan:
                plan.write(f"again-reset {ref}\n")
        if failure == "post-502":
            self.reply(502)
        elif failure in ("post-reset", "again-reset"):
            self.reset()
        else:
            answer = self.backend(body)
            if failure == "lost-502":
                self.reply(502)
            elif failure == "lost-reset":
                self.reset()
            else:
                self.reply(*answer)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE + ".new", "w", encoding="ascii") as port:
    port.write(str(server.server_address[1]))
os.replace(PORT_FILE + ".new", PORT_FILE)
server.serve_forever()
