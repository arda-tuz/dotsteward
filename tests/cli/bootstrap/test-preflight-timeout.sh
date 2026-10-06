# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # the scripts are expanded by the child bash
# The remote probe is bounded (20 seconds) also where timeout(1) does not
# exist (stock macOS before Nix): preflight_with_timeout of the stage-0 body
# falls back to a watchdog, keeps the command's exit status and stops a
# command that runs too long. Run with the stage-0 shell (bash 3.2 when the
# caller provides DS_BASH32) and a PATH without timeout.

shell=${DS_BASH32:-$BASH}
tools=$DS_TEST_ROOT/no-timeout-tools
mkdir -p "$tools"
for tool in sleep sh kill true false; do
  resolved=$(type -P "$tool" 2>/dev/null) || continue
  ln -s "$resolved" "$tools/$tool"
done
sed -n '/^# dotsteward:stage0:begin$/,/^# dotsteward:stage0:end$/p' \
  "$DS_REPO_ROOT/cli/commands/preflight.sh" >"$DS_TEST_ROOT/body.sh"

# in_body SCRIPT: SCRIPT after sourcing the body, in the stage-0 shell.
in_body() {
  env -i PATH="$tools" HOME="$HOME" "$shell" --norc --noprofile -c '
    set -Eeuo pipefail
    source "$1"
    command -v timeout >/dev/null 2>&1 && { echo "timeout is on PATH"; exit 99; }
    eval "$2"
  ' in-body "$DS_TEST_ROOT/body.sh" "$1"
}

assert_exit 0 in_body 'preflight_with_timeout 5 true'
assert_exit 7 in_body 'preflight_with_timeout 5 sh -c "exit 7"'
assert_exit 0 in_body 'out=$(preflight_with_timeout 5 sh -c "echo hello"); [[ $out == hello ]]'
start=$SECONDS
assert_exit 0 in_body 'status=0; preflight_with_timeout 1 sleep 30 || status=$?; ((status != 0))'
((SECONDS - start < 15)) || ds_fail "the watchdog did not stop the command (took $((SECONDS - start))s)"
# The watchdog does not hold a command substitution open.
start=$SECONDS
assert_exit 0 in_body 'out=$(preflight_with_timeout 20 sh -c "echo quick"); [[ $out == quick ]]'
((SECONDS - start < 10)) || ds_fail "the watchdog delayed a quick command (took $((SECONDS - start))s)"
