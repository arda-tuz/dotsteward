# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Sourced by the helpers of tests/upgrade, before the stubs. Not a test file.
# The tools of this machine stay out of reach: a test must not read its real channels, let alone
# start a real updater. Each tool a test wants is a tool_stub.
hide_tools() {
  python3 - "$DS_TEST_ROOT/up-hidden" "$@" <<'PY'
import os
import sys

farm, *hidden = sys.argv[1:]
result = []
for index, entry in enumerate(os.environ["PATH"].split(os.pathsep)):
    if not entry:
        continue
    if not any(os.path.lexists(os.path.join(entry, tool)) for tool in hidden):
        result.append(entry)
        continue
    copy = os.path.join(farm, str(index))
    os.makedirs(copy, exist_ok=True)
    for name in os.listdir(entry):
        if name not in hidden:
            os.symlink(os.path.join(entry, name), os.path.join(copy, name))
    result.append(copy)
print(os.pathsep.join(result))
PY
}
PATH=$(hide_tools snap flatpak fwupdmgr claude codex modinfo ubuntu-drivers uname)
tool_on_path_uname=$(command -v python3)
mkdir -p "$DS_TEST_ROOT/up-bin"
cat >"$DS_TEST_ROOT/up-bin/uname" <<UNAME
#!$BASH
"$tool_on_path_uname" -c 'import os, sys; print(os.uname().release if sys.argv[1:] == ["-r"] else os.uname().sysname)' "\$@"
UNAME
chmod 0755 "$DS_TEST_ROOT/up-bin/uname"
