#!/usr/bin/env python3
"""Runs a command on a terminal of its own and answers its questions, as a person would.

    terminal.py [--answer TEXT=REPLY]... -- COMMAND [ARG...]

Standard input, output and error of COMMAND are the terminal. Whenever TEXT shows up in its
output, REPLY and a newline go to the terminal, each answer once and in the given order. What
the terminal showed goes to standard output. The exit status is the status of COMMAND. An answer
never asked for is an error on standard error, with status 99: a question that should come did
not come. Silence for two minutes ends the command with status 98: a question nobody planned for.
"""

from __future__ import annotations

import argparse
import fcntl
import os
import pty
import select
import subprocess
import sys
import termios
import time

SILENCE_SECONDS = 120


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--answer", action="append", default=[])
    parser.add_argument("command", nargs=argparse.REMAINDER)
    options = parser.parse_args()
    command = options.command[1:] if options.command[:1] == ["--"] else options.command
    answers = [tuple(text.split("=", 1)) for text in options.answer]
    master, slave = pty.openpty()
    # The controlling terminal of a session of its own: sudo asks /dev/tty for the password.
    child = subprocess.Popen(
        command,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        start_new_session=True,
        preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0),
    )
    os.close(slave)
    seen = b""
    last_output = time.monotonic()
    while True:
        ready, _, _ = select.select([master], [], [], 0.1)
        if not ready:
            if child.poll() is not None:
                break
            if time.monotonic() - last_output > SILENCE_SECONDS:
                child.kill()
                tail = seen[-200:].decode(errors="replace")
                print(f"terminal.py: silent, waiting for an answer? {tail}", file=sys.stderr)
                return 98
            continue
        last_output = time.monotonic()
        try:
            data = os.read(master, 65536)
        except OSError:
            break
        if not data:
            break
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
        seen += data
        while answers and answers[0][0].encode() in seen:
            text, reply = answers.pop(0)
            seen = seen.split(text.encode(), 1)[1]
            os.write(master, reply.encode() + b"\n")
    status = child.wait()
    if answers:
        print(f"terminal.py: never asked: {answers[0][0]}", file=sys.stderr)
        return 99
    return status if status >= 0 else 128 - status


if __name__ == "__main__":
    sys.exit(main())
