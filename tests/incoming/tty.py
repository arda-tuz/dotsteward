"""Runs a command on a pseudo terminal, like a person: argv[1] holds the answers, one per
line, and each goes in when the output stops at a prompt. The output goes to standard
output with carriage returns removed; the exit status is the one of the command."""

import os
import pty
import select
import sys
import time

answers = [line for line in sys.argv[1].split("\n") if sys.argv[1]]
pid, fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[2], sys.argv[2:])
output = b""
typed = 0
deadline = time.monotonic() + 300
while time.monotonic() < deadline:
    ready, _, _ = select.select([fd], [], [], 0.2)
    if ready:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        output += chunk
        continue
    if typed < len(answers) and output.endswith(b": "):
        os.write(fd, answers[typed].encode() + b"\n")
        typed += 1
else:
    os.kill(pid, 9)
_, code = os.waitpid(pid, 0)
sys.stdout.write(output.decode("utf-8", "replace").replace("\r", ""))
sys.exit(os.waitstatus_to_exitcode(code))
