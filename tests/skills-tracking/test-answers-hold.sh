# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# An answer holds. What `--never` or `forget` keeps out stays out when an agent edits the
# copy later, when pending.json is gone and only the host file remembers, and when the
# checkout is behind. Only another answer takes it back. The copy of an own skill deleted
# here is not asked about again after `--never`.
# shellcheck source=tests/skills-tracking/capture-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/capture-helpers.sh"

new_machine a
root=$(home_of a)/.claude/skills

# --- --never, then a file tool writes -----------------------------------------------------

new_skill a nope
assert_exit 0 ds a skills reconcile
assert_eq ask "$(item a nope .state)"
ds_code a skills track nope --never
assert_eq declined "$(item a nope .state)"
assert_contains "$(remote_file hosts/a.toml)" nope
tip=$(remote_tip)
printf 'an edit by an agent\n' >>"$root/nope/SKILL.md"
wrote a nope
settle a nope
assert_eq declined "$(item a nope .state)"
ds_code a skills capture --now
assert_eq "$tip" "$(remote_tip)" "a declined skill stays out"
assert_eq "{}" "$(remote_entry nope)"

# The same with no pending.json; the checkout is behind, the host file on the remote knows.
rm -f "$(state_of a)/skills/pending.json"
printf 'another edit\n' >>"$root/nope/SKILL.md"
wrote a nope
settle a nope
ds_code a skills capture --now
assert_eq "$tip" "$(remote_tip)" "the host file of the tip remembers"
assert_eq "{}" "$(remote_entry nope)"
assert_eq declined "$(item a nope .state)"

# And with the host file in the checkout: nothing even waits.
git -C "$(clone_of a)" pull -q --ff-only
rm -f "$(state_of a)/skills/pending.json"
wrote a nope
assert_eq "{}" "$(item a nope .)"
assert_exit 0 ds a skills reconcile --full
assert_eq "{}" "$(item a nope .)"

# Another answer takes it back, and the host file says so.
ds_code a skills track nope --own
assert_eq nope "$(remote_entry nope | jq -r .name)"
assert_not_contains "$(remote_file hosts/a.toml)" nope

# --- forget, then a file tool writes ------------------------------------------------------

own_new a fg
settle a fg
ds_code a skills capture --now
assert_eq fg "$(remote_entry fg | jq -r .name)"
ds_code a skills forget fg
assert_eq "{}" "$(remote_entry fg)"
assert_eq forgotten "$(item a fg .state)"
tip=$(remote_tip)
printf 'an edit by an agent\n' >>"$root/fg/SKILL.md"
wrote a fg
settle a fg
assert_eq forgotten "$(item a fg .state)"
assert_exit 0 ds a skills reconcile --full
ds_code a skills capture --now
assert_eq "$tip" "$(remote_tip)" "a forgotten skill stays out"
assert_eq "{}" "$(remote_entry fg)"

# With a checkout that still has the entry in its lock (it did not pull), as well.
ds_code a skills track fg --own
assert_eq fg "$(remote_entry fg | jq -r .name)"
git -C "$(clone_of a)" pull -q --ff-only
ds_code a skills forget fg
assert_eq "{}" "$(remote_entry fg)"
tip=$(remote_tip)
assert_contains "$(git -C "$(clone_of a)" show HEAD:agent/skills.lock.json)" '"fg"'
printf 'one more edit\n' >>"$root/fg/SKILL.md"
wrote a fg
settle a fg
assert_eq forgotten "$(item a fg .state)"
ds_code a skills capture --now
assert_eq "$tip" "$(remote_tip)" "a stale lock brings nothing back"

# --- --never on an own skill deleted here -------------------------------------------------

git -C "$(clone_of a)" pull -q --ff-only
own_new a gone
settle a gone
ds_code a skills capture --now
rm -rf "${root:?}/gone"
assert_exit 0 ds a skills reconcile
pending=$(state_of a)/skills/pending.json
jq '.missing["skill:gone"] -= 120' "$pending" >"$pending.tmp"
mv -- "$pending.tmp" "$pending"
assert_exit 0 ds a skills reconcile
assert_eq deleted "$(item a gone .state)"
ds_code a skills track gone --never
assert_eq declined "$(item a gone .state)"
assert_exit 0 ds a skills reconcile
assert_json "$pending" '(.missing // {}) | has("skill:gone") | not'
assert_exit 0 ds a skills reconcile --full
assert_eq declined "$(item a gone .state)"
assert_eq null "$(item a gone .last_asked)"
assert_eq none "$(base a gone)"
