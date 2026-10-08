# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# `dotsteward contribute upgrade --tag TAG`:
# in the instance, `update prepare --scope maintain`, the dotsteward input
# of flake.nix moved to the tag (github:owner/repo/TAG, a git+ URL with
# ?ref=refs/tags/TAG, or a one-line block keeping its other parameters),
# `nix flake update dotsteward` (flake.lock must lock the tag's commit),
# bootstrap.sh and .dotsteward/cli.sh from the release's template/, sync,
# the gate after `git add -A`, one commit with commit.upgrade_subject,
# rebuild --switch and e2e (no override; e2e against the remote base),
# `update publish --scope maintain`; every step after the verified lock
# runs through the instance launcher (the CLI pinned by the new flake.lock,
# whose template/ the refreshed files match), only `update prepare` through
# the running CLI. Re-runs resume after the commit;
# --build-only rebuilds without switching and skips e2e; a red step keeps
# the instance's changes uncommitted and reports when the recovery cannot
# run on a dirty instance.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

rt_setup owner
write_flake git
released_run add-feature
merged=$(field .merged_sha)
base=$(git -C "$ct_inst" rev-parse HEAD)

# pinned COMMAND ARG...: the call log lines of COMMAND run through the
# instance launcher.
pinned() {
  call_line dotsteward-launcher "$@"
  call_line "dotsteward-$1" "${@:2}"
}

upgrade_calls() {
  call_line dotsteward-update prepare --official-sources-only --scope maintain
  pinned sync
  pinned gate --scope maintain
  pinned rebuild --profile main --switch
  pinned e2e --profile main --expected-remote-base "$base"
  pinned update publish --scope maintain --expected-base "$base"
}

# --- refusals -----------------------------------------------------------------------

assert_exit 1 run_contribute upgrade --tag v9.9.9
assert_contains "$DS_STDERR" "[dotsteward] ERROR: --tag v9.9.9 is not the release of run $(current_id) (v0.1.1)"
printf 'local\n' >"$ct_inst/notes.txt"
reset_calls
assert_exit 1 run_contribute upgrade --tag v0.1.1
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the instance $ct_inst has uncommitted changes; commit or remove them before the upgrade"
assert_eq "" "$(instance_calls)" "instance commands after the refusals"
rm -f "$ct_inst/notes.txt"

# --- flake.lock that does not lock the tag: stopped before any commit -----------------------

hub_knob lock-rev 0123456789abcdef0123456789abcdef01234567
reset_calls
assert_exit 1 run_contribute upgrade --tag v0.1.1
assert_contains "$DS_STDERR" "[dotsteward] ERROR: flake.lock locks dotsteward refs/tags/v0.1.1 at 0123456789abcdef0123456789abcdef01234567, not v0.1.1 at ${merged:0:12}; the upgrade stops before any commit"
assert_eq "$base" "$(git -C "$ct_inst" rev-parse HEAD)" "instance HEAD after a wrong lock"
assert_call_count 1 nix '*flake update dotsteward --flake *'
state_json | assert_json - ".instance_base == \"$base\" and .instance_commit == null and .step == \"upgrade\""

# The instance is dirty now (the upgrade's own changes): a re-run continues.
rm -f "$rt_hub/knobs/lock-rev"
reset_calls
assert_exit 0 run_contribute upgrade --tag v0.1.1
assert_eq "$(upgrade_calls)" "$(instance_calls)" "calls of the upgrade"
assert_contains "$(cat "$ct_inst/flake.nix")" '      url = "git+ssh://git@github.com/example-org/dotsteward?ref=refs/tags/v0.1.1";'
assert_contains "$(cat "$ct_inst/flake.nix")" '      # The framework release.'
jq -e --arg sha "$merged" '.nodes.dotsteward.locked.rev == $sha' "$ct_inst/flake.lock" >/dev/null ||
  ds_fail "flake.lock does not lock the release"
assert_eq "$(rt_bootstrap 0.1.1)" "$(cat "$ct_inst/bootstrap.sh")" "refreshed bootstrap.sh"
assert_file_mode "$ct_inst/bootstrap.sh" 755
assert_eq "$base" "$(git -C "$ct_inst" rev-parse HEAD^)" "one upgrade commit on the base"
assert_eq "chore(dotsteward): upgrade to 0.1.1" "$(git -C "$ct_inst" log -1 --format=%s)" "upgrade commit subject"
assert_eq "" "$(git -C "$ct_inst" log -1 --format=%b)" "upgrade commit body"
assert_eq "$(printf '%s\n' .dotsteward/synced bootstrap.sh flake.lock flake.nix)" \
  "$(git -C "$ct_inst" diff --name-only HEAD^ HEAD)" "files of the upgrade commit"
assert_eq "" "$(git -C "$ct_inst" status --porcelain)" "instance after the upgrade"
assert_eq pinned "$(live)" "live framework after the upgrade"
state_json | assert_json - ".instance_commit == \"$(git -C "$ct_inst" rev-parse HEAD)\" and .upgrade == \"full\""
state_json | assert_json - '.step == "report" and .trial_switched == false'
assert_contains "$DS_STDOUT" "[dotsteward] next: dotsteward contribute report"

reset_calls
assert_exit 0 run_contribute upgrade
assert_contains "$DS_STDOUT" "already upgraded the instance"
assert_calls

# --- a red e2e after the commit: resumed at the commit ------------------------------------

state_set '.step = "done"'
write_flake github
released_run second-feature 0.1.2
base=$(git -C "$ct_inst" rev-parse HEAD)
# An earlier recovery failed (its rebuild): the upgrade's switch replaces it.
state_set '.trial_switched = true | .recovery = "failed"'
printf 'switched\n' >"$rt_live"
stand_in_fail e2e '--profile main --expected-remote-base*'
reset_calls
assert_exit 1 run_contribute upgrade --tag v0.1.2
assert_contains "$DS_STDERR" "[dotsteward] ERROR: upgrade: e2e failed on the upgraded instance; run upgrade again once it is fixed"
assert_contains "$(cat "$ct_inst/flake.nix")" 'dotsteward.url = "github:example-org/dotsteward/v0.1.2";'
commit=$(git -C "$ct_inst" rev-parse HEAD)
assert_eq "$commit" "$(field .instance_commit)" "recorded instance commit"
assert_eq false "$(field .trial_switched)" "the upgrade's switch replaced the trial generation"
assert_eq null "$(field .recovery)" "the upgrade's switch replaced the failed recovery"
assert_not_contains "$DS_STDERR" "recovery"
assert_call_count 0 dotsteward-update 'publish*'
stand_in_clear e2e
reset_calls
assert_exit 0 run_contribute upgrade --tag v0.1.2
assert_contains "$DS_STDOUT" "[dotsteward] resuming the upgrade at the instance commit ${commit:0:12}"
assert_eq "$(
  pinned rebuild --profile main --switch
  pinned e2e --profile main --expected-remote-base "$base"
  pinned update publish --scope maintain --expected-base "$base"
)" "$(instance_calls)" "calls of the resumed upgrade"
assert_call_count 0 nix

# --- a red gate on a dirty instance: no commit, the recovery cannot run ----------------------

state_set '.step = "done"'
write_flake inline
released_run third-feature 0.1.3
base=$(git -C "$ct_inst" rev-parse HEAD)
state_set '.trial_switched = true'
stand_in_fail gate '--scope maintain'
reset_calls
assert_exit 1 run_contribute upgrade --tag v0.1.3
assert_contains "$DS_STDERR" "[dotsteward] ERROR: upgrade: the gate failed on the upgraded instance; the changes stay uncommitted (staged), nothing is published"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: recovery not run: the instance $ct_inst has uncommitted changes, so it cannot be rebuilt"
assert_contains "$(cat "$ct_inst/flake.nix")" 'inputs.dotsteward = { url = "github:example-org/dotsteward/v0.1.3?dir=."; flake = true; };'
assert_eq "$base" "$(git -C "$ct_inst" rev-parse HEAD)" "no commit after a red gate"
state_json | assert_json - '.trial_switched == true and .recovery == "failed" and .instance_commit == null'
assert_call_count 0 dotsteward-rebuild

# The instance moved meanwhile: refused.
stand_in_clear gate
git -C "$ct_inst" stash -q -u
git -C "$ct_inst" commit -q --allow-empty -m 'chore: something else'
assert_exit 1 run_contribute upgrade
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the instance moved since the upgrade started (HEAD"
git -C "$ct_inst" reset -q --hard "$base"
git -C "$ct_inst" stash pop -q

# --- build-only -------------------------------------------------------------------------------

reset_calls
assert_exit 0 run_contribute upgrade --build-only
assert_eq "$(
  call_line dotsteward-update prepare --official-sources-only --scope maintain
  pinned sync
  pinned gate --scope maintain
  pinned rebuild --profile main --build-only
  pinned update publish --scope maintain --expected-base "$base"
)" "$(instance_calls)" "calls of the build-only upgrade"
state_json | assert_json - '.upgrade == "build-only" and .step == "report"'
assert_contains "$DS_STDERR" "[dotsteward] WARNING: the live generation still uses the trial framework (a build-only upgrade does not switch); switch to the upgraded instance with: dotsteward rebuild --profile main --switch"
assert_eq "chore(dotsteward): upgrade to 0.1.3" "$(git -C "$ct_inst" log -1 --format=%s)" "build-only upgrade commit"

# --- an instance that already uses the release: nothing to commit or publish --------------

state_set '.step = "done"'
write_flake github
released_run fifth-feature 0.1.4
sed -i 's|dotsteward/v0.1.0|dotsteward/v0.1.4|' "$ct_inst/flake.nix"
nix flake update dotsteward --flake "$ct_inst"
git -C "$ct_clone" show v0.1.4:template/bootstrap.sh >"$ct_inst/bootstrap.sh"
instance_commit 'chore(dotsteward): upgrade to 0.1.4 by hand'
base=$(git -C "$ct_inst" rev-parse HEAD)
reset_calls
assert_exit 0 run_contribute upgrade --tag v0.1.4
assert_contains "$DS_STDOUT" "[dotsteward] the instance already uses v0.1.4"
assert_contains "$DS_STDOUT" "[dotsteward] nothing to publish: the instance's published commit ${base:0:12} already uses v0.1.4"
assert_eq "$base" "$(git -C "$ct_inst" rev-parse HEAD)" "no commit for an instance on the release"
assert_eq "$base" "$(field .instance_commit)" "instance commit of an instance on the release"
assert_eq "$(
  call_line dotsteward-update prepare --official-sources-only --scope maintain
  pinned sync
  pinned gate --scope maintain
  pinned rebuild --profile main --switch
  pinned e2e --profile main
)" "$(instance_calls)" "calls of the upgrade of an instance on the release"
assert_eq report "$(field .step)" "step of an instance on the release"

# --- unsupported flake.nix -------------------------------------------------------------------

state_set '.step = "done"'
printf '{ inputs = { }; outputs = _: { }; }\n' >"$ct_inst/flake.nix"
instance_commit 'chore: a flake without the input'
released_run fourth-feature 0.1.5
assert_exit 1 run_contribute upgrade
assert_contains "$DS_STDERR" "[dotsteward] ERROR: cannot find the one url of the dotsteward input in $ct_inst/flake.nix; set it to the tag v0.1.5 by hand and run upgrade again"
