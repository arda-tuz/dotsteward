# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# What `forget` and `--never` keep out stays out as long as a copy of the skill is around,
# and once the copy is gone the name is all that is left: `skills status` says it for ever
# and the host file carries it. `skills forget --clear` is the answer that ends it: it
# takes the name out of the host file and the pending state, and asks about nothing.
# It refuses while a copy is there, and a name that nothing keeps out.
# shellcheck source=tests/skills-tracking/capture-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/capture-helpers.sh"

new_machine a
root=$(home_of a)/.claude/skills

own_new a leftover
settle a leftover
ds_code a skills capture --now
ds_code a skills forget leftover
assert_contains "$(remote_file hosts/a.toml)" leftover
assert_eq forgotten "$(item a leftover .state)"

# While a copy is there, another answer takes it back: nothing moves.
tip=$(remote_tip)
EXPECT_STATUS=1 ds_code a skills forget leftover --clear
assert_contains "$DS_STDERR$DS_STDOUT" "$root/leftover"
assert_eq "$tip" "$(remote_tip)"
assert_eq forgotten "$(item a leftover .state)"

# The copy goes, and the name stays: this is what has no way out without this command.
rm -rf "${root:?}/leftover"
ds_code a skills reconcile --full
assert_eq forgotten "$(item a leftover .state)"
ds_code a skills status
assert_contains "$DS_STDOUT" "skill:leftover: forgotten"
assert_contains "$DS_STDOUT" "dotsteward skills forget --clear leftover"

ds_code a skills forget leftover --clear
assert_eq "{}" "$(item a leftover .)"
assert_not_contains "$(remote_file hosts/a.toml)" leftover
assert_eq "chore(skills): clear leftover" "$(git -C "$remote" log -1 --format=%s)"
ds_code a skills status
assert_not_contains "$DS_STDOUT" leftover

# Done is done: nothing keeps it out any more.
tip=$(remote_tip)
EXPECT_STATUS=1 ds_code a skills forget leftover --clear
assert_contains "$DS_STDERR$DS_STDOUT" "nothing keeps leftover out"
assert_eq "$tip" "$(remote_tip)"

# A new skill of that name is a new skill: the machine asks again.
git -C "$(clone_of a)" pull -q --ff-only
new_skill a leftover
ds_code a skills reconcile
assert_eq ask "$(item a leftover .state)"
rm -rf "${root:?}/leftover"
ds_code a skills reconcile

# --- --never leaves the same name behind -------------------------------------------------------

new_skill a declined-one
ds_code a skills reconcile
ds_code a skills track declined-one --never
assert_contains "$(remote_file hosts/a.toml)" declined-one
rm -rf "${root:?}/declined-one"
ds_code a skills forget declined-one --clear
assert_eq "{}" "$(item a declined-one .)"
assert_not_contains "$(remote_file hosts/a.toml)" declined-one

# --- only the host file remembers: pending.json is gone, the checkout has the name -------------

own_new a hostonly
settle a hostonly
ds_code a skills capture --now
ds_code a skills forget hostonly
rm -rf "${root:?}/hostonly"
git -C "$(clone_of a)" pull -q --ff-only
rm -f "$(state_of a)/skills/pending.json"
assert_contains "$(git -C "$(clone_of a)" show HEAD:hosts/a.toml)" hostonly
ds_code a skills forget hostonly --clear
assert_not_contains "$(remote_file hosts/a.toml)" hostonly

# --- a machine without a name: pending.json is all there is, and no commit is needed -----------

new_machine b
rm -f "$(state_of b)/machine.json"
unnamed() {
  on b env -u DOTSTEWARD_MACHINE "$DS_REPO_ROOT/cli/dotsteward" "$@" </dev/null >/dev/null ||
    ds_fail "$* on a machine without a name"
}
own_new b unnamed-one
settle b unnamed-one
unnamed skills capture --now
unnamed skills forget unnamed-one
assert_eq forgotten "$(item b unnamed-one .state)"
rm -rf "$(home_of b)/.claude/skills/unnamed-one"
tip=$(remote_tip)
unnamed skills forget unnamed-one --clear
assert_eq "{}" "$(item b unnamed-one .)"
assert_eq "$tip" "$(remote_tip)" "nothing to publish"
