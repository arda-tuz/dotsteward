# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Atomic file writes (dotsteward_cli.atomic): a reader sees the old file or the
# new one, never a part of it, also after a crash. Temporary file in the same
# directory, fsync, rename, fsync of the directory; a crash leaves the old file
# and at most a temporary file of a dead process, which the next write of that
# file removes.
# shellcheck source=tests/cli/core/helpers.sh
source "$DS_REPO_ROOT/tests/cli/core/helpers.sh"

work=$DS_TEST_ROOT/atomic
mkdir -p "$work"
target=$work/file.json

# --- the internal command ------------------------------------------------------------

printf 'first\n' | internal atomic-write "$target"
assert_eq 'first' "$(<"$target")"
assert_file_mode "$target" 644

# Parent directories appear when asked for; an explicit mode counts; a later
# write without a mode keeps the mode of the file; a file is replaced, not
# rewritten in place.
assert_exit 1 internal atomic-write "$work/new/dir/private" </dev/null
assert_contains "$DS_STDERR" "[dotsteward] ERROR: cannot write $work/new/dir/private: No such file or directory"
[[ ! -e $work/new ]] || ds_fail "the directories appeared unasked"
printf 'private\n' | internal atomic-write "$work/new/dir/private" --mode 0600 --parents
assert_eq 'private' "$(<"$work/new/dir/private")"
assert_file_mode "$work/new/dir/private" 600
printf 'again\n' | internal atomic-write "$work/new/dir/private"
assert_eq 'again' "$(<"$work/new/dir/private")"
assert_file_mode "$work/new/dir/private" 600
exec 9<"$target"
printf 'second\n' | internal atomic-write "$target"
assert_eq 'first' "$(cat <&9)" "a reader that opened the old file keeps reading the old file"
exec 9<&-
assert_eq 'second' "$(<"$target")"

# The bytes as they are: no newline added, none removed, not text.
printf 'no newline' | internal atomic-write "$work/raw"
assert_eq 10 "$(wc -c <"$work/raw" | tr -d ' ')"
printf '\377\000\n' | internal atomic-write "$work/binary"
assert_eq 3 "$(wc -c <"$work/binary" | tr -d ' ')"

# A symbolic link is replaced by the file; what it pointed at stays.
printf 'linked\n' >"$work/link-target"
ln -s "$work/link-target" "$work/link"
printf 'replaced\n' | internal atomic-write "$work/link"
[[ ! -L $work/link ]] || ds_fail "the link is still a link"
assert_eq 'replaced' "$(<"$work/link")"
assert_eq 'linked' "$(<"$work/link-target")"

# Refusals: a usage error, an invalid mode, a directory that cannot be written.
assert_exit 2 internal atomic-write
assert_exit 1 internal atomic-write "$work/bad-mode" --mode 9999 </dev/null
assert_contains "$DS_STDERR" "[dotsteward] ERROR: "
[[ ! -e $work/bad-mode ]] || ds_fail "an invalid mode wrote a file"
mkdir "$work/readonly"
chmod 555 "$work/readonly"
ds_defer chmod 755 "$work/readonly"
assert_exit 1 internal atomic-write "$work/readonly/file" </dev/null
assert_contains "$DS_STDERR" "[dotsteward] ERROR: cannot write $work/readonly/file: "
assert_not_contains "$DS_STDERR" "Traceback"

# --- the order of the system calls ----------------------------------------------------

core_python - "$work/ordered" <<'PY' || ds_fail "the order of fsync and rename"
import os
import stat
import sys

from dotsteward_cli import atomic

path = sys.argv[1]
events = []
real_fsync, real_replace = os.fsync, os.replace


def fsync(fd):
    kind = "directory" if stat.S_ISDIR(os.fstat(fd).st_mode) else "file"
    events.append(f"fsync {kind}")
    real_fsync(fd)


def replace(source, destination):
    assert os.path.dirname(source) == os.path.dirname(destination), source
    with open(source, "rb") as handle:
        assert handle.read() == b"data", "the temporary file holds the data before the rename"
    events.append("rename")
    real_replace(source, destination)


os.fsync, os.replace = fsync, replace
atomic.atomic_write(path, b"data")
assert events == ["fsync file", "rename", "fsync directory"], events
assert open(path, "rb").read() == b"data"
PY

# --- a crash between the write and the rename ------------------------------------------

printf 'old\n' >"$work/crash"
crash_driver='
import os
import signal
import sys

from dotsteward_cli import atomic


def die(source, destination):
    os.kill(os.getpid(), signal.SIGKILL)


os.replace = die
atomic.atomic_write(sys.argv[1], b"new\n")
'
status=0
core_python -c "$crash_driver" "$work/crash" || status=$?
assert_eq 137 "$status" "the writer died by SIGKILL"
assert_eq 'old' "$(<"$work/crash")" "the old file survives the crash"
leftovers() {
  find "$work" -maxdepth 1 -name '.crash.*' -print
}
[[ -n $(leftovers) ]] || ds_fail "the crash left no temporary file: the test proves nothing"

# The next write of the same file succeeds and removes the leftover of the dead
# process; the temporary file of a writer that still runs stays.
sleep 300 &
live=$!
ds_defer kill "$live"
printf 'partial' >"$work/.crash.$live.abcdefgh.tmp"
core_python -c '
import os
import sys

from dotsteward_cli import atomic

atomic.atomic_write(sys.argv[1], b"new\n")
' "$work/crash"
assert_eq 'new' "$(<"$work/crash")"
assert_eq "$work/.crash.$live.abcdefgh.tmp" "$(leftovers)" "only the file of a live writer stays"
kill "$live"
wait "$live" 2>/dev/null || true
rm -f -- "$work/.crash.$live.abcdefgh.tmp"

# --- a failure between the write and the rename ----------------------------------------

printf 'old\n' >"$work/failing"
core_python - "$work/failing" <<'PY' || ds_fail "a failed rename"
import os
import sys

from dotsteward_cli import atomic


def fail(source, destination):
    raise PermissionError(13, "synthetic", destination)


real = os.replace
os.replace = fail
try:
    atomic.atomic_write(sys.argv[1], b"new\n")
except PermissionError:
    pass
else:
    raise AssertionError("the failure was swallowed")
os.replace = real
assert open(sys.argv[1], "rb").read() == b"old\n"
PY
assert_eq '' "$(find "$work" -maxdepth 1 -name '.failing.*' -print)" "a failed write leaves no temporary file"

# --- text, JSON and the interface for Python ---------------------------------------------

core_python - "$work" <<'PY' || ds_fail "the Python interface"
import json
import os
import stat
import sys
from pathlib import Path

from dotsteward_cli import atomic

work = Path(sys.argv[1])
atomic.atomic_write(work / "text", "caf\u00e9\r\n")
assert (work / "text").read_bytes() == "caf\u00e9\r\n".encode(), "text is UTF-8 without newline translation"
atomic.atomic_write_json(work / "doc.json", {"b": 1, "a": ["\u00e9"]})
assert (work / "doc.json").read_text(encoding="utf-8") == '{\n  "b": 1,\n  "a": [\n    "\u00e9"\n  ]\n}\n'
assert json.loads((work / "doc.json").read_text(encoding="utf-8")) == {"b": 1, "a": ["\u00e9"]}
os.umask(0o077)
atomic.atomic_write(work / "umask", b"x")
assert stat.S_IMODE(os.stat(work / "umask").st_mode) == 0o644, "the mode of a new file does not depend on the umask"
PY

# --- many writers, one reader ------------------------------------------------------------

# Whatever a reader sees is one whole version.
shared=$work/shared
printf '%s' "$(printf 'x%.0s' {1..1000})" >"$shared"
writer_driver='
import sys

from dotsteward_cli import atomic

path, letter = sys.argv[1:]
for _ in range(40):
    atomic.atomic_write(path, letter.encode() * 200000)
open(f"{path}.done.{letter}", "w").close()
'
pids=()
for letter in a b c; do
  core_python -c "$writer_driver" "$shared" "$letter" &
  pids+=($!)
done
reader_driver='
import os
import sys
import time

path = sys.argv[1]
deadline = time.monotonic() + 120
while not all(os.path.exists(f"{path}.done.{letter}") for letter in "abc"):
    if time.monotonic() > deadline:
        sys.exit("the writers did not finish")
    with open(path, "rb") as handle:
        data = handle.read()
    if len(set(data)) != 1:
        sys.exit(f"a torn read: {sorted(set(data))}")
'
core_python -c "$reader_driver" "$shared" || ds_fail "a reader saw a partial file"
for pid in "${pids[@]}"; do
  wait "$pid" || ds_fail "a writer failed"
done
assert_eq '' "$(find "$work" -maxdepth 1 -name '.shared.*' -print)" "the writers left a temporary file"

# --- one implementation ----------------------------------------------------------------

# The lock files and the settings engine write through it.
others=$(grep -rnE 'os\.replace|os\.fsync|mkstemp' "$DS_REPO_ROOT/cli/python" "$DS_REPO_ROOT/engines" --include='*.py' |
  grep -v 'cli/python/dotsteward_cli/atomic.py' || true)
assert_eq "" "$others" "another atomic write"
