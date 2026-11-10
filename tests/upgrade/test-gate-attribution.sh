# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub and the gate hooks run later and are single-quoted on purpose
# A red gate holds only the pins it can be put on. The run bisects by the groups of the writer: the
# gate runs again on the tip with only some groups moved, until one group is red by itself; that
# group is held, and when the gate is green with every other group, those go on in the same run.
# When no group is red by itself (a red that needs two of them), nothing can be put on one group:
# every moved pin is held, and the run says the red could not be attributed.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
holds=$DOTSTEWARD_STATE_ROOT/holds.json

# gate_red_when JQ: the gate is red while JQ holds for the lock of the tree it proves.
gate_red_when() {
  printf 'if jq -e %q "$DOTSTEWARD_INSTANCE/versions.lock.json" >/dev/null; then : >%q; else rm -f -- %q; fi\n' \
    "$1" "$UP_CONTROL/static-red" "$UP_CONTROL/static-red" >"$UP_CONTROL/during-gate"
}

# --- one group is red by itself --------------------------------------------------------------
move example.broken 2.0 pypi:broken
move example.fine 1.1 npm:fine
move agent_tools.codex.linux 2.0.0 download
gate_red_when '."example.broken" == "2.0"'
assert_exit 3 upgrade --tracked
assert_json "$holds" '[.holds[].id] == ["example.broken"]'
assert_json "$holds" '.holds[0].reason | contains("pypi:broken")'
review_json '[.items[] | select(.code == "red-held") | .id] == ["example.broken"]'
review_json '[.items[] | select(.code == "gate-failed")][0] | .attribution == "pypi:broken" and .held == ["example.broken"]'
assert_contains "$DS_STDOUT" "example.broken 2.0 stays back"
# The rest went on in the same run: committed, rebuilt, checked and published.
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"
assert_eq "1.1 2.0.0 null" "$(jq -r '[."example.fine", ."agent_tools.codex.linux", ."example.broken"] | map(. // "null") | join(" ")' "$up_inst/versions.lock.json")"
assert_order '^static ' '^static ' '^static ' '^static ' '^rebuild ' '^e2e '
assert_eq 4 "$(steps '^static ' | wc -l | tr -d ' ')" "the gate of the move, one bisection, the group alone, the rest"

# --- a red that needs two groups: no attribution, everything held -------------------------------
clear_log
before=$(remote_oid)
rm -f -- "$UP_CONTROL/moves"
move example.left 1.0 left
move example.right 1.0 right
gate_red_when '."example.left" == "1.0" and ."example.right" == "1.0"'
assert_exit 1 upgrade --tracked
assert_json "$holds" '[.holds[].id] | sort == ["example.broken", "example.left", "example.right"]'
review_json '[.items[] | select(.code == "gate-failed")][0] | .attribution == null'
assert_contains "$DS_STDOUT" "could not be attributed"
assert_eq "null null" "$(jq -r '[."example.left", ."example.right"] | map(. // "null") | join(" ")' "$up_inst/versions.lock.json")"
assert_eq "$before" "$(remote_oid)" "nothing was published"
work_gone
rm -f -- "$UP_CONTROL/during-gate" "$UP_CONTROL/static-red"
