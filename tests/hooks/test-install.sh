# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# The hook file itself: present, executable (also in the index, so a fresh
# clone gets a runnable hook), a bash script, and a no-op when git reports no
# ref updates. Installation in the dev checkout is `git config
# core.hooksPath .githooks` (checked by the task's acceptance commands; the
# six-leak drill pushes through a relative hooksPath).
# shellcheck source=tests/hooks/helpers.sh
source "$DS_REPO_ROOT/tests/hooks/helpers.sh"

[[ -f $HOOK ]] || ds_fail "missing hook: .githooks/pre-push"
[[ -x $HOOK ]] || ds_fail "the hook is not executable"
assert_eq "#!/usr/bin/env bash" "$(head -n 1 "$HOOK")"
if git -C "$DS_REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  mode=$(git -C "$DS_REPO_ROOT" ls-files -s -- .githooks/pre-push | cut -d ' ' -f 1)
  if [[ -n $mode ]]; then
    assert_eq 100755 "$mode" "the hook is executable in the index"
  fi
fi

# Nothing to push (no ref lines): nothing to check, no denylist needed.
hook_repo repo
cd repo
assert_exit 0 "$HOOK" origin ../repo.git </dev/null
assert_eq "" "$DS_STDOUT$DS_STDERR"

# Only deletions: nothing to check either.
zero=$(printf '%040d' 0)
assert_exit 0 "$HOOK" origin ../repo.git <<<"(delete) $zero refs/heads/old $(git rev-parse HEAD)"

# A malformed ref line is an error, never a silent pass.
write_denylist "$(rand_word 12)"
assert_exit 1 "$HOOK" origin ../repo.git <<<"refs/heads/main $(git rev-parse HEAD)"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: pre-push: unexpected input line"
assert_contains "$DS_STDERR" "push refused"

# The hook needs the remote name argument git always passes.
assert_exit 1 "$HOOK" </dev/null
assert_contains "$DS_STDERR" "[dotsteward] ERROR: pre-push: usage: pre-push REMOTE [URL]"
assert_no_hook_temp
