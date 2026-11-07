# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# An own skill another machine changed: the old copy stays until the person says otherwise.
# shellcheck source=tests/incoming/helpers.sh
source "$DS_REPO_ROOT/tests/incoming/helpers.sh"

machine_up laptop1
machine_up laptop2
captured laptop1 foo
assert_exit 0 ds laptop1 skills status --json
up_to_date laptop2
assert_exit 0 ds laptop2 incoming answer skill:foo --install
up_to_date laptop1

copy=$(home_of laptop2)/.agents/skills/foo
old=$(<"$copy/SKILL.md")
old_digest=$(base laptop2 foo)
edited laptop1 foo 'the second version'
up_to_date laptop2
new_digest=$(remote_entry foo | jq -r .directory_sha256)

# Ask later: the old copy stays through every command, green, nothing stored.
assert_exit 0 ds laptop2 incoming list --json
assert_json - '.items[0].id == "skill:foo" and .items[0].change == "changed" and .items[0].by == "laptop1"' <<<"$DS_STDOUT"
assert_exit 0 agents laptop2 install --skip-validation
assert_eq "$old" "$(<"$copy/SKILL.md")" "agents install leaves it"
assert_eq "$old_digest" "$(base laptop2 foo)"
assert_exit 0 agents laptop2 check
assert_eq '[]' "$(skipped laptop2 skills)" "it stays linked and checked"
assert_contains "$(ask_on_tty laptop2 l incoming)" 'skill foo (changed) - machine laptop1'
assert_eq "$old" "$(<"$copy/SKILL.md")"

# The difference is what an install would do to this copy.
assert_exit 0 ds laptop2 incoming show skill:foo
assert_contains "$DS_STDOUT" '+the second version'

# Install: the backup, the new copy, b is the lock.
assert_exit 0 ds laptop2 incoming answer skill:foo --install
assert_contains "$(<"$copy/SKILL.md")" 'the second version'
assert_eq "$new_digest" "$(base laptop2 foo)"
assert_eq 1 "$(find "$(state_of laptop2)/backups" -name SKILL.md -path '*foo*' | wc -l)" "one backup"
assert_eq '' "$(waiting laptop2)"

# A change here and there: that is a conflict, which has its own question.
up_to_date laptop1
edited laptop1 foo 'the third version'
up_to_date laptop2
printf 'a change here\n' >>"$copy/SKILL.md"
assert_eq '' "$(waiting laptop2)"
assert_exit 0 ds laptop2 skills status --json
assert_json - '.own[] | select(.name == "foo") | .state == "conflict"' <<<"$DS_STDOUT"
sed -i '$d' "$copy/SKILL.md"

# Never: the copy stays and tracking ends.
assert_eq 'skill:foo' "$(waiting laptop2)"
before=$(<"$copy/SKILL.md")
assert_exit 0 ds laptop2 incoming answer skill:foo --never
assert_eq "$before" "$(<"$copy/SKILL.md")"
assert_eq none "$(base laptop2 foo)"
assert_eq '' "$(waiting laptop2)"
assert_exit 0 ds laptop2 skills reconcile --full
assert_eq none "$(item laptop2 foo '.state // "none"')"
assert_exit 0 agents laptop2 check
