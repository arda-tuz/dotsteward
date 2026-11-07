# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# E6: sudo closes during the window. On a terminal it is asked once more and the window goes on;
# a second failure hands the rest over in review.json, and everything that needs no sudo still runs.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude
ds_stub_set sudo env UP_CONTROL

# The password runs out after recovery: `sudo -n` fails once, `sudo -v` opens it again.
cat >"$DS_TEST_ROOT/up-bin/sudo" <<SUDO
#!$BASH
printf 'sudo %s\n' "\$*" >>"$UP_LOG"
if [[ \$1 == -n && -e "$UP_CONTROL/timed-out" ]]; then
  printf 'sudo: a password is required\n' >&2
  exit 1
fi
if [[ \$1 == -v ]]; then
  [[ ! -e "$UP_CONTROL/refuse-password" ]] || exit 1
  rm -f "$UP_CONTROL/timed-out"
fi
exec "$sudo_stub" "\$@"
SUDO

# After recovery the fake helper lets the window run out.
cat >"$DS_TEST_ROOT/fakes/apt-python" <<FAKE
#!$BASH
FAKE
cat >>"$DS_TEST_ROOT/fakes/apt-python" <<'FAKE'
action=$3
output=$5
request=$(cat)
printf 'apt %s %s\n' "$action" "$(jq -c '{mode, tracked}' <<<"$request")" >>"$UP_LOG"
if [[ -n ${output:-} ]]; then cp -- "$UP_APT/$action.json" "$output"; else cat -- "$UP_APT/$action.json"; fi
if [[ $action == recover && -e $UP_CONTROL/time-out-after-recover ]]; then
  : >"$UP_CONTROL/timed-out"
  rm -f "$UP_CONTROL/time-out-after-recover"
fi
FAKE
export UP_CONTROL
: >"$UP_CONTROL/time-out-after-recover"
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_eq 2 "$(steps '^sudo -v' | wc -l | tr -d ' ')" "asked once more"
assert_order '^apt recover' '^apt policy' '^apt commit' '^sudo -k'

# The second try fails too: review.json holds the rest, and Nix work still runs.
clear_log
: >"$UP_CONTROL/time-out-after-recover"
: >"$UP_CONTROL/refuse-password-after"
cat >"$DS_TEST_ROOT/up-bin/sudo" <<SUDO
#!$BASH
printf 'sudo %s\n' "\$*" >>"$UP_LOG"
if [[ \$1 == -n && -e "$UP_CONTROL/timed-out" ]]; then
  printf 'sudo: a password is required\n' >&2
  exit 1
fi
if [[ \$1 == -v && -e "$UP_CONTROL/timed-out" ]]; then
  exit 1
fi
exec "$sudo_stub" "\$@"
SUDO
assert_exit 3 on_terminal 'Update these too=n' -- --tracked
assert_order '^apt recover' '^pins .*apply'
assert_no_step '^apt commit'
review_json '[.items[] | select(.code == "sudo-required")] | length == 1'

# Sudo refuses at the very start: the whole window waits, the rest runs.
clear_log
: >"$UP_CONTROL/timed-out"
assert_exit 3 on_terminal 'Update these too=n' -- --tracked
assert_no_step '^apt (recover|policy|commit)'
assert_order '^pins .*apply'
review_json '[.items[] | select(.code == "sudo-required")] | length == 1'
