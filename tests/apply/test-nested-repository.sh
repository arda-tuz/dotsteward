# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# A git repository inside the checkout (a cloned skill, say) would be staged as a gitlink: an empty
# directory on every other machine, whose content no scan has seen. apply refuses it before the
# gate, names the path and leaves it out of the index; once its files are plain files of the
# instance, the same apply goes on.
# shellcheck source=tests/apply/helpers.sh
source "$DS_REPO_ROOT/tests/apply/helpers.sh"

base=$(remote_oid)
assert_exit 0 begin
nested=$up_inst/agent/skills/cloned
mkdir -p "$nested"
git -C "$nested" init -q
printf -- '---\nname: cloned\n---\n' >"$nested/SKILL.md"
git -C "$nested" add -A
git -C "$nested" -c user.name=x -c user.email=x@example.invalid commit -qm init

clear_log
assert_exit 1 apply -m "feat: a cloned skill" --activate --publish
assert_contains "$DS_STDERR" "agent/skills/cloned"
assert_no_step '^static '
assert_eq "$base" "$(head_oid)"
assert_eq "" "$(git -C "$up_inst" ls-files --stage agent/skills)" "the gitlink is not staged"

# Vendored as plain files, it goes through.
rm -rf -- "$nested/.git"
clear_log
assert_exit 0 apply -m "feat: a cloned skill" --activate --publish
assert_eq "$(head_oid)" "$(remote_oid)"
assert_eq "100644" "$(git -C "$up_inst" ls-tree HEAD agent/skills/cloned/SKILL.md | cut -d' ' -f1)"
