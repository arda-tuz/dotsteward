# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and up_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# The world of the hold tests (not a test file): tests/upgrade/helpers.sh, a named producer, the
# binaries of codex, and readers of the host files on the remote.
#
#   remote_holds NAME    the holds table of hosts/NAME.toml on the remote, as JSON
#   files_of COMMIT      the paths a commit of the remote changed
#   first_since COMMIT   the oldest commit of main after COMMIT
#   gate_red_when JQ     the gate is red while JQ holds for the lock it proves
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\necho old\n' >"$HOME/.local/bin/codex"
printf '#!/bin/sh\necho old helper\n' >"$HOME/.local/bin/codex-helper"
chmod 0755 "$HOME/.local/bin/codex" "$HOME/.local/bin/codex-helper"
set_toml hosts producer '"example-host"'
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "chore(hosts): example-host produces the pins"
git -C "$up_inst" push -q origin HEAD:main

remote_holds() {
  git -C "$up_bare" show "main:hosts/$1.toml" |
    python3 -c 'import json, sys, tomllib; print(json.dumps(tomllib.loads(sys.stdin.read()).get("holds", {}), sort_keys=True))'
}
files_of() {
  git -C "$up_bare" show --format= --name-only "$1"
}
first_since() {
  git -C "$up_bare" rev-list --reverse "$1..main" | sed -n 1p
}
gate_red_when() {
  printf 'if jq -e %q "$DOTSTEWARD_INSTANCE/versions.lock.json" >/dev/null; then : >%q; else rm -f -- %q; fi\n' \
    "$1" "$UP_CONTROL/static-red" "$UP_CONTROL/static-red" >"$UP_CONTROL/during-gate"
}
