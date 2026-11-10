# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub and the gate hooks run later and are single-quoted on purpose
# A red gate holds only what it can be put on, and never an innocent group. The run first gates the
# tip itself: when that is red, the moves are not what broke the gate, nothing is held and the item
# says the base is red. Else it looks for the groups of the writer the red needs, by the gate of the
# tip with all moves but a part of them: a group without which the gate is green is held, and the
# others go on in the same run. A group that only fails without another one is not held. When the
# red cannot be put on one group, the whole set is gated once more (a red that is not there again
# moves everything); still red, every moved pin is held and the item says it could not be attributed.
# The held ids join the skips, so a publish that runs again does not move them again.
# Another machine that publishes meanwhile changes nothing of this: the publish runs again on its tip.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
holds=$DOTSTEWARD_STATE_ROOT/holds.json

# gate_red_when JQ [HOOK]: the gate is red while JQ holds for the lock of the tree it proves; HOOK
# runs too, with N the number of this gate.
gate_red_when() {
  {
    printf 'n=$(( $(cat %q 2>/dev/null || echo 0) + 1 )); echo "$n" >%q\n' "$UP_CONTROL/gate-count" "$UP_CONTROL/gate-count"
    printf 'if jq -e %q "$DOTSTEWARD_INSTANCE/versions.lock.json" >/dev/null; then : >%q; else rm -f -- %q; fi\n' \
      "$1" "$UP_CONTROL/static-red" "$UP_CONTROL/static-red"
    printf '%s\n' "${2:-}"
  } >"$UP_CONTROL/during-gate"
  rm -f -- "$UP_CONTROL/gate-count"
}
lock_of_remote() {
  git -C "$up_bare" show main:versions.lock.json | jq -r "$1"
}
reset_moves() {
  clear_log
  rm -f -- "$UP_CONTROL/moves" "$holds"
}

# --- one group is red by itself: held, the rest goes on in the same run, four gates ------------------
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
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"
assert_eq "1.1 2.0.0 null" "$(lock_of_remote '[."example.fine", ."agent_tools.codex.linux", ."example.broken"] | map(. // "null") | join(" ")')"
assert_eq 4 "$(steps '^static ' | wc -l | tr -d ' ')" "the gate of the move, the base, two halvings of the suspects"

# --- a group that needs another one: only the broken one is held -----------------------------------
reset_moves
move example.needs-b 1.0 npm:a
move example.b 1.0 npm:b
move example.c 1.0 npm:c
gate_red_when '(."example.needs-b" == "1.0" and ."example.b" != "1.0") or ."example.c" == "1.0"'
assert_exit 3 upgrade --tracked
assert_json "$holds" '[.holds[].id] == ["example.c"]'
assert_eq "1.0 1.0 null" "$(lock_of_remote '[."example.needs-b", ."example.b", ."example.c"] | map(. // "null") | join(" ")')"

# --- a red that needs two groups: one of them is held, the other goes on --------------------------
reset_moves
move example.left 1.0 left
move example.right 1.0 right
gate_red_when '."example.left" == "1.0" and ."example.right" == "1.0"'
assert_exit 3 upgrade --tracked
assert_json "$holds" '[.holds[].id] == ["example.left"]'
assert_eq "null 1.0" "$(lock_of_remote '[."example.left", ."example.right"] | map(. // "null") | join(" ")')"

# --- the base itself is red: nothing is held, nothing goes out -------------------------------------
# A tip no gate has proven yet: another machine published it (a tree the gate proved answers from
# its memo).
reset_moves
printf 'a page of another machine\n' >"$up_inst/other-page.md"
git -C "$up_inst" add other-page.md
git -C "$up_inst" commit -q -m "docs: a page of another machine"
git -C "$up_inst" push -q origin HEAD:main
before=$(remote_oid)
move example.one 1.0 one
move example.two 1.0 two
gate_red_when 'true'
assert_exit 1 upgrade --tracked
[[ ! -e $holds ]] || assert_json "$holds" '.holds | length == 0'
review_json '[.items[] | select(.code == "gate-failed")][0] | .base_red == true and .held == []'
assert_contains "$DS_STDOUT" "the base is red"
assert_eq "$before" "$(remote_oid)" "nothing was published"
assert_eq 2 "$(steps '^static ' | wc -l | tr -d ' ')" "the gate of the move and the base"
work_gone

# --- every group is red by itself: once more the whole set, then everything is held ------------------
reset_moves
move example.x 1.0 x
move example.y 1.0 y
move example.z 1.0 z
gate_red_when '."example.x" == "1.0" or ."example.y" == "1.0" or ."example.z" == "1.0"'
assert_exit 1 upgrade --tracked
assert_json "$holds" '[.holds[].id] | sort == ["example.x", "example.y", "example.z"]'
review_json '[.items[] | select(.code == "gate-failed")][0] | .attribution == null'
assert_contains "$DS_STDOUT" "could not be attributed"

# --- the same, but the whole set is green when it is gated once more: nothing is held -----------------
reset_moves
move example.flaky 1.0 flaky
move example.other 1.0 other
gate_red_when '."example.flaky" == "1.0" or ."example.other" == "1.0"' 'key=$(sha256sum "$DOTSTEWARD_INSTANCE/versions.lock.json" | cut -d" " -f1)
if [[ $n == 1 ]]; then echo "$key" >"'"$UP_CONTROL"'/first"; elif [[ $key == "$(cat "'"$UP_CONTROL"'/first")" ]]; then rm -f -- "'"$UP_CONTROL"'/static-red"; fi'
assert_exit 3 upgrade --tracked
[[ ! -e $holds ]] || assert_json "$holds" '.holds | length == 0'
assert_eq "1.0 1.0" "$(lock_of_remote '[."example.flaky", ."example.other"] | join(" ")')"

# --- another machine publishes during the bisection: held as before, the rest goes out on its tip -----
reset_moves
move example.broken2 2.0 npm:c
move example.fine2 1.1 pypi:fine
gate_red_when '."example.broken2" == "2.0"' "[[ \$n != 2 ]] || {
  clone=$DS_TEST_ROOT/other-machine
  rm -rf -- \"\$clone\"; git clone -q $(printf %q "$up_bare") \"\$clone\"
  printf 'x\\n' >>\"\$clone/other-page-2.md\"; git -C \"\$clone\" add -A
  git -C \"\$clone\" commit -q -m 'docs: other'
  git -C \"\$clone\" push -q origin HEAD:main; rm -rf -- \"\$clone\"
}"
assert_exit 3 upgrade --tracked
assert_json "$holds" '[.holds[].id] == ["example.broken2"]'
assert_eq "1.1 null" "$(lock_of_remote '[."example.fine2", ."example.broken2"] | map(. // "null") | join(" ")')"
git -C "$up_bare" show main:other-page-2.md >/dev/null || ds_fail "the commit of the other machine is lost"
assert_contains "$(steps '^pins .*apply' | tail -n 1)" "--skip example.broken2"
rm -f -- "$UP_CONTROL/during-gate" "$UP_CONTROL/static-red"
