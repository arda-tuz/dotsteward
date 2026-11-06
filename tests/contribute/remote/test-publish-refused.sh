# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# `dotsteward contribute publish` makes a read or a push again only after a
# failure of the network (test-publish-network.sh). A verdict is never made
# again: a push the remote refuses (a protected branch, a main that moved) or
# the pre-push hook refuses (a privacy finding), and a repository that does
# not exist. Each is one connection and no pause, even with a long time to
# keep trying.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

export DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS=30

rt_setup owner

# --- a push the remote refuses: red, recovered, main untouched --------------------------------------

checked_run refused-feature 0.1.1
mark_trialled full true
printf 'trial\n' >"$rt_live"
refused=$(git -C "$ct_clone" rev-parse HEAD)
before=$(upstream_main)
hub_knob push-main refuse
: >"$DS_FAKESSH_LOG"
reset_calls
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "protected branch: pushes to main are refused"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: pushing ${refused:0:12} to main of $CT_UPSTREAM_SLUG was refused; main is untouched"
assert_not_contains "$DS_STDERR" "trying again"
assert_eq 2 "$(pushes_served)" "pushes served: the branch and the refused push to main, once"
assert_eq "$before" "$(upstream_main)" "upstream main after the refused push"
assert_eq pinned "$(live)" "the refused push runs the recovery"
hub_knob push-main none

# A main that moved at the last moment is a verdict too: the branch goes
# back to check at once.
mark_trialled full false
hub_knob push-main race
: >"$DS_FAKESSH_LOG"
assert_exit 5 run_contribute publish
assert_not_contains "$DS_STDERR" "trying again"
assert_eq 1 "$(pushes_served)" "pushes served: the push to main that no longer fast-forwards, once"
assert_eq check "$(field .step)" "step after main moved"

# A finding of the pre-push hook: the push is refused before it is sent.
mark_checked
mark_trialled full false
mkdir -p "$DS_TEST_ROOT/refusing-hooks"
printf '#!%s\nprintf "[dotsteward] ERROR: pre-push: a finding\\n" >&2\nexit 1\n' "$BASH" >"$DS_TEST_ROOT/refusing-hooks/pre-push"
chmod 0755 "$DS_TEST_ROOT/refusing-hooks/pre-push"
git -C "$ct_clone" config core.hooksPath "$DS_TEST_ROOT/refusing-hooks"
main_before=$(upstream_main)
: >"$DS_FAKESSH_LOG"
assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "[dotsteward] ERROR: pre-push: a finding"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: pushing fix/refused-feature to origin failed; nothing is published"
assert_not_contains "$DS_STDERR" "trying again"
assert_eq 1 "$(pushes_served)" "connections of the push that the hook refused"
assert_eq "$main_before" "$(upstream_main)" "upstream main after the hook's refusal"
git -C "$ct_clone" config --unset core.hooksPath

# --- a repository that does not exist is no network failure ----------------------------------

: >"$DS_TEST_ROOT/empty.map"
mark_trialled full false
DS_FAKESSH_MAP=$DS_TEST_ROOT/empty.map assert_exit 1 run_contribute publish
assert_contains "$DS_STDERR" "ERROR: Repository not found."
assert_contains "$DS_STDERR" "[dotsteward] ERROR: cannot list the tags of origin"
assert_not_contains "$DS_STDERR" "trying again"

