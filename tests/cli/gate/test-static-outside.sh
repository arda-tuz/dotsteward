# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The static step runs outside the sandbox only the static checks that need
# this machine: the [gate] static scripts with DOTSTEWARD_SANDBOX=0 (the
# parts they keep out of the sandbox, such as a launcher or a command
# check) and, when [privacy] names a denylist (a file outside the instance,
# which the sandbox never reads), the privacy scan with it. Every other
# static check runs once, in the sandbox, in instance-contract of the flake
# check, so the gate never runs a whole static pass twice.
# shellcheck source=tests/cli/gate/helpers.sh
source "$DS_REPO_ROOT/tests/cli/gate/helpers.sh"

ds_use_stubs nix curl
serve_cache

# No denylist: the scripts only.
assert_exit 0 run_gate --scope maintain
assert_eq "static --only scripts" "$(fake_calls | head -n 1)"
assert_eq "== static: dotsteward static --only scripts" "$(grep '^== static: ' "$gate_log")"
assert_eq "$(nix_line flake check "$gate_inst" --no-update-lock-file --keep-going -L --max-jobs 5 --cores 3)" \
  "$(ds_calls_of nix | grep -F ' flake check ')"

# A denylist: its privacy scan too.
denylist=$DS_TEST_ROOT/denylist.txt
printf 'private-term\n' >"$denylist"
gate_config "[privacy]
denylist = \"$denylist\""
: >"$DS_CALL_LOG"
assert_exit 0 run_gate --scope maintain
assert_eq "static --only privacy --only scripts" "$(fake_calls | head -n 1)"
assert_eq "== static: dotsteward static --only privacy --only scripts" "$(grep '^== static: ' "$gate_log")"

# A failing check of the step still stops the gate before the flake check.
mkdir -p "$gate_inst/notes"
printf 'a\n' >"$gate_inst/notes/a.txt"
commit_all "docs: add a note"
step_fail static 1
: >"$DS_CALL_LOG"
assert_exit 1 run_gate --scope maintain
assert_contains "$DS_STDERR" "[dotsteward] ERROR: gate step failed: static; full log: $gate_log"
assert_call_count 0 nix '*flake check*'
