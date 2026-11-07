# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the commands of the declarations run later and are single-quoted on purpose
# The framework names the channels of the system (apt, snap, flatpak) and nothing else: every other
# updater is what the instance declares in [[upgrade.tools]], and all of them are treated alike. A
# tool that is not declared is not run even when it is on PATH. A line of `check` is one thing to
# update; the commands run in the checkout. 127 means not on this machine, any other failure is said
# and ends nothing, and a tool with nothing to update does not update. Items that provide a tracked
# command stay out of `update`, also when nobody can say what they provide. Offline nothing is run.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
tool_stub example-undeclared 'case "$1" in check) printf "something 1 2\n";; esac'

# --- nothing declared: the system channels only -------------------------------------------------
assert_exit 0 upgrade --plan --json
assert_stdout_json '.channels | keys == ["flatpak", "snap"]'
assert_no_step '^example-undeclared'

# --- the kinds of answer ---------------------------------------------------------------------------
tool_stub example-many 'case "$1" in
  outdated) printf "first 1 2\n\nsecond 1 2\nprovider 1 2\nmystery 1 2\n";;
  provides) case "$2" in provider) printf "other codex\n";; mystery) exit 3;; *) printf "%s\n" "$2";; esac;;
esac'
tool_stub example-none 'exit 0'
tool_stub example-broken 'printf "the index is broken\n" >&2; exit 5'
declare_tool example-many 'example-many outdated' 'example-many update "$@"' 'example-many provides "$1"'
declare_tool example-none 'example-none outdated' 'example-none update'
declare_tool example-broken 'example-broken outdated' 'example-broken update'
declare_tool example-absent 'example-not-installed outdated' 'example-not-installed update'
declare_tool example-where 'printf "%s\n" "$PWD" >"$DS_TEST_ROOT/where"; printf "here 1 2\n"' 'printf "%s\n" "$PWD" >>"$DS_TEST_ROOT/where"'

assert_exit 0 upgrade --plan --json
assert_stdout_json '.channels["example-many"].available and .channels["example-many"].count == 2'
assert_stdout_json '.channels["example-many"].items == [{"name": "first", "line": "first 1 2"}, {"name": "second", "line": "second 1 2"}]'
assert_stdout_json '.channels["example-many"].skipped == [
  {"name": "provider", "reason": "tracked-command"}, {"name": "mystery", "reason": "providers-unknown"}]'
assert_stdout_json '.channels["example-none"] == {"available": true, "count": 0, "items": [], "skipped": []}'
assert_stdout_json '.channels["example-broken"].count == 0 and (.channels["example-broken"].error | contains("the index is broken"))'
assert_stdout_json '.channels["example-absent"] == {"available": false, "count": 0}'
assert_eq "$up_inst" "$(<"$DS_TEST_ROOT/where")"
assert_no_step 'update'

# What a person reads.
assert_exit 0 upgrade --plan
assert_contains "$DS_STDOUT" "example-many 2 (first, second) (tracked commands left out: 2)"
assert_contains "$DS_STDOUT" "example-none 0"
assert_contains "$DS_STDOUT" "example-broken: could not be read: the index is broken"
assert_contains "$DS_STDOUT" "example-absent: not on this machine"

# The menu names what is declared.
clear_log
assert_exit 0 on_terminal 'Update what=2' --
assert_contains "$DS_STDOUT" "2) Everything (apt, snap, flatpak, example-many, example-none, example-broken, example-absent, example-where)"
assert_order '^example-many update first second$'
assert_no_step '^example-many update .*(provider|mystery)'
assert_no_step '^example-none update'
assert_no_step '^example-broken update'
assert_eq "$up_inst" "$(sed -n 2p "$DS_TEST_ROOT/where")"
last_report '[.steps[] | select(.name == "tool:example-many") | .status] == ["ok"]'
last_report '[.steps[] | select(.name == "tool:example-none")] == []'

# A declared update that fails is said and ends nothing.
tool_stub example-many 'case "$1" in outdated) printf "first 1 2\n";; update) exit 7;; esac'
clear_log
assert_exit 1 upgrade --all
last_report '[.steps[] | select(.name == "tool:example-many") | .status] == ["failed"]'
assert_order '^example-many update first$'
last_report '[.steps[] | select(.name == "tool:example-where")] | length == 1'

# --- offline: no declared command runs -------------------------------------------------------------
: >"$UP_CONTROL/network-down"
clear_log
assert_exit 0 upgrade --plan --json
assert_stdout_json '.channels["example-many"] == {"available": true, "count": 0, "skipped": "offline"}'
assert_no_step '^example-many'
