# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# Whatever keeps a skill waiting for more than a day is said, not only a missing network: a
# launcher that cannot run, a capture that fails for any reason. Nobody reads capture.log.
# shellcheck source=tests/skills-tracking/capture-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/capture-helpers.sh"

wrap_git
new_machine a
new_machine b
HOOK_ENV=(CLAUDE_CODE_SESSION_ATTENDED=1)

# --- the checks cannot run ----------------------------------------------------------------

elsewhere=$DS_TEST_ROOT/elsewhere
git clone -q "$remote" "$elsewhere"
printf '#!/bin/sh\nexit 127\n' >"$elsewhere/.dotsteward/cli.sh"
git -C "$elsewhere" add -A
git -C "$elsewhere" commit -q -m "chore: a launcher that cannot run"
git -C "$elsewhere" push -q origin main
own_new a stuck
settle a stuck
EXPECT_STATUS=6 ds_code a skills capture --now
assert_eq capture "$(item a stuck .state)"
assert_eq checks-unavailable "$(item a stuck .reason)"
hook_on a SessionStart session-start
assert_not_contains "$HOOK_OUT" stuck
age_field a skill:stuck offline_since 90000
hook_on a SessionStart session-start
assert_contains "$HOOK_OUT" stuck
assert_contains "$HOOK_OUT" "dotsteward skills status"

# --- a capture fails for a reason nobody expected -----------------------------------------

own_new b failing
settle b failing
export GIT_WRAP_FAIL_WORKTREE=1
EXPECT_STATUS=1 ds_code b skills capture --now
unset GIT_WRAP_FAIL_WORKTREE
assert_eq capture "$(item b failing .state)"
assert_eq capture-failed "$(item b failing .reason)"
since=$(item b failing .offline_since)
[[ $since != null ]] || ds_fail "the time it started to wait is kept"
ds_code b skills status
assert_contains "$DS_STDOUT" "capture-failed"
age_field b skill:failing offline_since 90000
hook_on b SessionStart session-start
assert_contains "$HOOK_OUT" failing
