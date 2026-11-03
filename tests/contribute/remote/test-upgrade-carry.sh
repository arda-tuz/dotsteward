# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# `dotsteward contribute upgrade --carry`: an instance whose HEAD has
# commits that origin lacks (a maintain transaction blocked by the
# framework defect the run fixed) is refused without --carry, and the
# refusal names it. With --carry the commits are saved (a ref of the run),
# the instance is reset to origin, upgraded, and the commits are applied
# again on top of the upgrade commit (authors and messages kept, UTC
# dates); sync runs again (mirrors that changed are folded into the last
# carried commit) and the gate checks the whole tree before rebuild, e2e
# and publish, which ship the upgrade and the carried commits together. A
# conflict in the generated mirrors only is resolved with the upgrade's
# mirrors; any other conflict stops with the cherry-pick in progress, and
# the upgrade continues once it is resolved and continued by hand.
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

rt_setup owner
released_run add-feature
base=$(git -C "$ct_inst" rev-parse HEAD)

# pinned COMMAND ARG...: the call log lines of COMMAND run through the
# instance launcher.
pinned() {
  call_line dotsteward-launcher "$@"
  call_line "dotsteward-$1" "${@:2}"
}

# maintain_commit SUBJECT FILE CONTENT: an unpublished instance commit.
maintain_commit() {
  printf '%s\n' "$3" >"$ct_inst/$2"
  git -C "$ct_inst" add -A
  git -C "$ct_inst" commit -q -m "$1"
}

# published: what update publish (a stand-in here) pushes.
published() {
  git -C "$ct_inst" push -q origin HEAD:main
}

maintain_commit "feat(components): add example-widget" components.txt example-widget
maintain=$(git -C "$ct_inst" rev-parse HEAD)
maintain_author=$(git -C "$ct_inst" log -1 --format='%an <%ae> %ad' "$maintain")

# --- without --carry: refused, and the refusal names it ---------------------------------

reset_calls
assert_exit 1 run_contribute upgrade --tag v0.1.1
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the instance HEAD ${maintain:0:12} differs from origin/main (${base:0:12}): 1 unpublished commit(s) that origin lacks; publish or remove them first, or carry them across the upgrade with: dotsteward contribute upgrade --tag v0.1.1 --carry"
assert_eq "" "$(instance_calls)" "instance commands after the refusal"
assert_eq "$maintain" "$(git -C "$ct_inst" rev-parse HEAD)" "the instance is untouched"
state_json | assert_json - '.carry == null and .instance_base == null and .step == "upgrade"'

# --- with --carry: saved, reset, upgraded, applied again on top, validated -----------------

reset_calls
assert_exit 0 run_contribute upgrade --tag v0.1.1 --carry
assert_contains "$DS_STDOUT" "[dotsteward] carrying 1 unpublished instance commit(s) across the upgrade: saved as refs/dotsteward/carry/$(current_id) (${maintain:0:12}); the upgrade starts from origin/main (${base:0:12})"
assert_eq "$(
  call_line dotsteward-update prepare --official-sources-only --scope maintain
  pinned sync
  pinned gate --scope maintain
  pinned sync
  pinned gate --scope maintain
  pinned rebuild --profile main --switch
  pinned e2e --profile main --expected-remote-base "$base"
  pinned update publish --scope maintain --expected-base "$base"
)" "$(instance_calls)" "calls of the carrying upgrade"
assert_eq "chore(dotsteward): upgrade to 0.1.1
feat(components): add example-widget" "$(git -C "$ct_inst" log --reverse --format=%s "$base..HEAD")" \
  "the upgrade commit, then the carried commit"
assert_eq "$maintain_author" "$(git -C "$ct_inst" log -1 --format='%an <%ae> %ad')" "the carried commit keeps its author"
[[ $(git -C "$ct_inst" log -1 --format=%cd --date=format:%z) == +0000 ]] || ds_fail "the carried commit's date is not UTC"
assert_eq example-widget "$(cat "$ct_inst/components.txt")" "the carried change"
assert_contains "$(cat "$ct_inst/flake.nix")" 'dotsteward.url = "github:example-org/dotsteward/v0.1.1";'
assert_eq "" "$(git -C "$ct_inst" status --porcelain)" "instance after the carrying upgrade"
if git -C "$ct_inst" rev-parse --verify --quiet "refs/dotsteward/carry/$(current_id)" >/dev/null; then
  ds_fail "the carry ref outlived the upgrade"
fi
state_json | assert_json - ".instance_commit == \"$(git -C "$ct_inst" rev-parse HEAD)\" and .upgrade_commit == \"$(git -C "$ct_inst" rev-parse HEAD^)\""
state_json | assert_json - '.carry.applied == true and .step == "report"'
published

# --- a conflict outside the mirrors: stopped, continued by hand, resumed -----------------------

state_set '.step = "done"'
released_run second-feature 0.1.2
base=$(git -C "$ct_inst" rev-parse HEAD)
sed -i 's|dotsteward/v0.1.1";|dotsteward/v0.1.1"; # pinned by hand|' "$ct_inst/flake.nix"
printf 'hand\n' >"$ct_inst/notes.txt"
git -C "$ct_inst" add -A
git -C "$ct_inst" commit -q -m "fix(flake): note the pin"
conflicting=$(git -C "$ct_inst" rev-parse HEAD)
reset_calls
assert_exit 1 run_contribute upgrade --tag v0.1.2 --carry
assert_contains "$DS_STDERR" "[dotsteward] ERROR: carrying the instance commit ${conflicting:0:12} conflicts with the upgrade in flake.nix: resolve it in $ct_inst, git add the files and run 'git cherry-pick --continue' (repeat until it is done; 'git cherry-pick --abort' starts the carry over), then run: dotsteward contribute upgrade --tag v0.1.2 --carry"
git -C "$ct_inst" rev-parse --verify --quiet CHERRY_PICK_HEAD >/dev/null || ds_fail "the cherry-pick is not left in progress"
state_json | assert_json - '.instance_commit == null and .upgrade_commit != null and .carry.applied == false'
assert_call_count 0 dotsteward-rebuild

# Run again before it is resolved: the same instructions, nothing else.
reset_calls
assert_exit 1 run_contribute upgrade
assert_contains "$DS_STDERR" "[dotsteward] ERROR: carrying the instance commits stopped on a conflict in $ct_inst: resolve it, git add the files and run 'git cherry-pick --continue' there"
assert_eq "" "$(instance_calls)" "instance commands while the conflict waits"

# Resolved by hand (the upgrade's flake.nix), continued, then resumed.
git -C "$ct_inst" checkout -q --ours -- flake.nix
git -C "$ct_inst" add flake.nix
(cd "$ct_inst" && GIT_EDITOR=true TZ=UTC git cherry-pick --continue) >/dev/null 2>&1
reset_calls
assert_exit 0 run_contribute upgrade
assert_contains "$DS_STDOUT" "[dotsteward] the carried commits are on top of the upgrade commit"
assert_eq "$(
  pinned sync
  pinned gate --scope maintain
  pinned rebuild --profile main --switch
  pinned e2e --profile main --expected-remote-base "$base"
  pinned update publish --scope maintain --expected-base "$base"
)" "$(instance_calls)" "calls of the resumed carrying upgrade"
assert_eq "chore(dotsteward): upgrade to 0.1.2
fix(flake): note the pin" "$(git -C "$ct_inst" log --reverse --format=%s "$base..HEAD")" "history after the resolved carry"
assert_contains "$(cat "$ct_inst/flake.nix")" 'dotsteward.url = "github:example-org/dotsteward/v0.1.2";'
assert_eq hand "$(cat "$ct_inst/notes.txt")" "the rest of the carried commit"
published

# --- conflicts in the generated mirrors only: resolved by sync, folded in -------------------------

state_set '.step = "done"'
released_run third-feature 0.1.3
base=$(git -C "$ct_inst" rev-parse HEAD)
mirror=$(cd "$ct_inst" && ls .dotsteward/manifest.*.json)
# The carried commit changed its mirror with the old framework; the
# upgrade's sync writes the mirror from the instance files.
printf 'old framework mirror\n' >"$ct_inst/$mirror"
maintain_commit "feat(components): add example-gadget" components.txt example-gadget
hub_knob sync-mirror on
reset_calls
assert_exit 0 run_contribute upgrade --tag v0.1.3 --carry
assert_contains "$DS_STDOUT" "[dotsteward] folded the synced mirrors into the last carried commit"
assert_eq "chore(dotsteward): upgrade to 0.1.3
feat(components): add example-gadget" "$(git -C "$ct_inst" log --reverse --format=%s "$base..HEAD")" "history after the mirror conflict"
assert_eq "mirror of: example-gadget" "$(cat "$ct_inst/$mirror")" "the mirror synced from the carried change"
assert_eq "" "$(git -C "$ct_inst" status --porcelain)" "instance after the mirror conflict"
published
rm -f "$rt_hub/knobs/sync-mirror"

# --- abort while a carry waits on a conflict: the saved commits are named ---------------------------

state_set '.step = "done"'
released_run fourth-feature 0.1.4
sed -i 's|dotsteward/v0.1.3";|dotsteward/v0.1.3"; # pinned by hand again|' "$ct_inst/flake.nix"
git -C "$ct_inst" commit -q -am "fix(flake): note the pin again"
held=$(git -C "$ct_inst" rev-parse HEAD)
assert_exit 1 run_contribute upgrade --tag v0.1.4 --carry
git -C "$ct_inst" cherry-pick --abort
reset_calls
assert_exit 0 run_contribute abort
assert_contains "$DS_STDOUT" "[dotsteward] the instance commits carried across the upgrade stay saved as refs/dotsteward/carry/$(current_id) (${held:0:12}); get them back with: git -C $ct_inst reset --hard ${held:0:12}"
assert_eq "$held" "$(git -C "$ct_inst" rev-parse "refs/dotsteward/carry/$(current_id)")" "the saved commits after abort"

# --- behind origin: refused without --carry, fast-forwarded with it --------------------------------

git -C "$ct_inst" reset -q --hard "$(git -C "$ct_inst" rev-parse origin/main)"
state_set '.step = "done"'
released_run fifth-feature 0.1.5
other=$DS_TEST_ROOT/other-checkout
git clone -q "$rt_inst_bare" "$other"
printf 'elsewhere\n' >"$other/elsewhere.txt"
git -C "$other" add -A
git -C "$other" commit -q -m "chore: a commit published from another checkout"
git -C "$other" push -q origin HEAD:main
remote=$(git -C "$other" rev-parse HEAD)
behind=$(git -C "$ct_inst" rev-parse HEAD)
assert_exit 1 run_contribute upgrade --tag v0.1.5
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the instance HEAD ${behind:0:12} is behind origin/main (${remote:0:12}); run 'git pull --ff-only' in $ct_inst first"
reset_calls
assert_exit 0 run_contribute upgrade --tag v0.1.5 --carry
assert_contains "$DS_STDOUT" "[dotsteward] the instance was behind origin/main: fast-forwarded to ${remote:0:12}, nothing to carry"
assert_eq "$(
  call_line dotsteward-update prepare --official-sources-only --scope maintain
  pinned sync
  pinned gate --scope maintain
  pinned rebuild --profile main --switch
  pinned e2e --profile main --expected-remote-base "$remote"
  pinned update publish --scope maintain --expected-base "$remote"
)" "$(instance_calls)" "calls of an upgrade with nothing to carry"
assert_eq "$remote" "$(git -C "$ct_inst" rev-parse HEAD^)" "the upgrade commit on the fast-forwarded instance"
state_json | assert_json - '.carry == null and .step == "report"'
