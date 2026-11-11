# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# On a consumer that holds back a shared lock (T19), `apply --activate` of a tree whose shared lock
# is the one that went red here is refused before the gate and before any commit: the change stays
# as it is, and the message names the way on. Without --activate the change is committed as always.
# shellcheck source=tests/apply/helpers.sh
source "$DS_REPO_ROOT/tests/apply/helpers.sh"

mkdir -p "$up_inst/hosts"
printf 'schema_version = 1\n' >"$up_inst/hosts/other-host.toml"
set_toml hosts producer '"other-host"'
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "chore(hosts): make other-host the producer"
git -C "$up_inst" push -q origin HEAD:main

head=$(git -C "$up_inst" rev-parse HEAD)
digest=$(PYTHONPATH=$fw/cli/python python3 -c '
import sys
from pathlib import Path
from dotsteward_cli.upgrade import consumer
print(consumer.lock_digest(Path(sys.argv[1]), sys.argv[2]))' "$up_inst" "$head")
mkdir -p "$DOTSTEWARD_STATE_ROOT/upgrade"
jq -n --arg lock "$digest" --arg commit "$head" '{schema_version: 1, commit: ("1" * 40), lock_commit: $commit,
  lock: $lock, components: ["codex"], at: "2026-11-01T00:00:00Z"}' >"$DOTSTEWARD_STATE_ROOT/upgrade/held-at.json"

printf 'a change\n' >"$up_inst/docs/other.md"
clear_log
assert_exit 1 apply -m "docs: a change" --activate
assert_contains "$DS_STDERR" "this machine holds back the shared lock of ${head:0:12}: it went red here (codex)"
assert_contains "$DS_STDERR" "--no-activate"
assert_eq "$head" "$(git -C "$up_inst" rev-parse HEAD)" "nothing was committed"
assert_contains "$(git -C "$up_inst" status --porcelain)" "docs/other.md"
assert_no_step '^rebuild '
assert_no_step '^gate '
