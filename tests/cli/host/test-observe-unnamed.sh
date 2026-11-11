# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# A machine without a name yet (before `dotsteward host init`) has nothing to record, and
# `dotsteward observe` is a quiet no-op there that still waits for dpkg to settle first: an
# apt run writes the status file again and again, and a service that ended at once on each
# write would be started many times a second (systemd then stops the path unit). One run per
# apt run, one line, exit 0, nothing written.
# shellcheck source=tests/cli/host/observe-helpers.sh
source "$DS_REPO_ROOT/tests/cli/host/observe-helpers.sh"

add_component example-editor deb '{"packageNames": ["example-editor"]}'
publish_instance "chore: one component"
pkg example-editor 1.2.3-1

started=$SECONDS
assert_exit 0 "$agents_fw/cli/dotsteward" --instance "$agents_inst" observe --settle-seconds 2 </dev/null
((SECONDS - started >= 2)) || ds_fail "the observer of an unnamed machine did not wait for dpkg to settle"
assert_eq "[dotsteward] this machine has no name yet: 'dotsteward host init' names it: nothing to observe" "$DS_STDOUT"
assert_eq "" "$DS_STDERR"
[[ ! -e $DOTSTEWARD_STATE_ROOT/observe ]] || ds_fail "the observer of an unnamed machine wrote something"
assert_eq "" "$(git -C "$agents_inst" for-each-ref refs/heads/state)"

# A lock dpkg holds keeps it waiting too, without a limit while the lock is there.
lock_line /var/lib/dpkg/lock-frontend >"$DS_SYSTEM_ROOT/proc/locks"
(sleep 2 && : >"$DS_SYSTEM_ROOT/proc/locks") &
releaser=$!
started=$SECONDS
assert_exit 0 run_observe --wait-limit 0
took=$((SECONDS - started))
wait "$releaser"
((took >= 2)) || ds_fail "the observer of an unnamed machine went on while dpkg held its lock"
assert_contains "$DS_STDOUT" "nothing to observe"
