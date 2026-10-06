# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# G2, the gate lock ([gate] I6): while another process holds
# <state>/update/validate.lock the gate refuses at once (no waiting) with
# exit 1, before the untracked check and before any Nix or step command;
# once the lock is free the same gate runs.
# shellcheck source=tests/cli/gate/helpers.sh
source "$DS_REPO_ROOT/tests/cli/gate/helpers.sh"

ds_use_stubs nix curl
serve_cache

mkdir -p "$gate_state"
ready=$DS_TEST_ROOT/lock-held
# The holder execs into sleep, so killing it releases the lock.
# shellcheck disable=SC2016 # expanded by the inner shell
bash -c 'exec 9>>"$1" && flock --exclusive 9 && touch "$2" && exec sleep 120' bash "$gate_lockfile" "$ready" &
holder=$!
ds_defer kill "$holder"
for _ in $(seq 1 200); do
  [[ -e $ready ]] && break
  sleep 0.05
done
[[ -e $ready ]] || ds_fail "the lock holder did not start"

# An untracked file would be refused too: the lock comes first.
printf 'draft\n' >"$gate_inst/notes.txt"
started=$SECONDS
assert_exit 1 run_gate --scope maintain
assert_eq "[dotsteward] ERROR: another gate is running; wait for it to finish" "$DS_STDERR"
assert_eq "" "$DS_STDOUT"
(((SECONDS - started) < 10)) || ds_fail "the gate waited for the lock"
assert_calls
[[ ! -e $gate_validation && ! -e $gate_log ]] || ds_fail "the refused gate wrote state"
assert_file_mode "$gate_state" 700

kill "$holder"
wait "$holder" 2>/dev/null || true
rm -f -- "$gate_inst/notes.txt"
assert_exit 0 run_gate --scope maintain
assert_json "$gate_validation" '.result == "passed"'
