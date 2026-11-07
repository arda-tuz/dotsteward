# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# The logs of skill tracking are as private as the rest of its state, whatever the umask: a
# new log, a log from before this rule, and a log that starts over when it is too long.
# shellcheck source=tests/skills-tracking/helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/helpers.sh"

umask 0002
tracking_on
install_hooks claude
AGENT_ENV=(CLAUDE_CODE_SESSION_ATTENDED=1 CLAUDE_CODE_ENTRYPOINT=cli)

ds_cli skills capture --now </dev/null >/dev/null 2>&1 || true
[[ -f $ss/capture.log ]] || ds_fail "a capture run leaves capture.log"
assert_file_mode "$ss/capture.log" 600

# A log from before: the next line tightens it.
chmod 0664 "$ss/capture.log"
ds_cli skills capture --now </dev/null >/dev/null 2>&1 || true
assert_file_mode "$ss/capture.log" 600

# A log that starts over.
head -c 2000000 /dev/zero | tr '\0' 'x' >"$ss/capture.log"
chmod 0664 "$ss/capture.log"
ds_cli skills capture --now </dev/null >/dev/null 2>&1 || true
assert_file_mode "$ss/capture.log" 600
[[ $(wc -c <"$ss/capture.log") -lt 2000000 ]] || ds_fail "a log that is too long starts over"

# hook-errors.log: a hook that fails on its way writes it, and still exits 0. A pending
# state that is a directory is such a failure, and the state directory stays writable.
rm -f "$ss/hook-errors.log"
rm -f "$ss/pending.json"
mkdir -p "$ss/pending.json/x"
agent_event claude SessionStart session-start
assert_eq 0 "$EVENT_STATUS"
rm -rf "$ss/pending.json"
[[ -f $ss/hook-errors.log ]] || ds_fail "a hook that failed leaves hook-errors.log"
assert_file_mode "$ss/hook-errors.log" 600
chmod 0664 "$ss/hook-errors.log"
mkdir -p "$ss/pending.json/x"
agent_event claude SessionStart session-start
rm -rf "$ss/pending.json"
assert_file_mode "$ss/hook-errors.log" 600
