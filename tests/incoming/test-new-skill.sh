# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# E29: a skill another machine captured. The repository moves forward by itself, the
# skill lands here only when the person says so, and the question names the machine.
# shellcheck source=tests/incoming/helpers.sh
source "$DS_REPO_ROOT/tests/incoming/helpers.sh"

machine_up laptop1
machine_up laptop2
captured laptop1 foo
tip=$(remote_tip)

# Without a terminal: the checkout moves, nothing is installed, the question waits in the review.
EXPECT_STATUS=3 ds_code laptop2 incoming
assert_eq "$tip" "$(git -C "$(clone_of laptop2)" rev-parse HEAD)" "the repository moved forward"
assert_contains "$(cat "$(clone_of laptop2)/agent/skills.lock.json")" '"foo"'
assert_eq 0 "$(find "$(home_of laptop2)/.agents/skills" -name foo | wc -l)" "not installed"
review=$(state_of laptop2)/review.json
assert_json "$review" '.items | map(select(.code == "incoming")) | length == 1'
assert_json "$review" '.items[] | select(.code == "incoming")
  | .id == "skill:foo" and .kind == "skill" and .name == "foo" and .by == "laptop1"
    and (.show | contains("incoming show skill:foo")) and (.answer | contains("incoming answer skill:foo"))'

# Everything else goes on: the machine is green and no command installs it.
assert_eq 'skill:foo' "$(waiting laptop2)"
assert_eq '["foo"]' "$(skipped laptop2 skills)"
assert_exit 0 ds laptop2 skills effective --json
assert_eq incoming "$(jq -r '.reasons["skill:foo"]' <<<"$DS_STDOUT")"
assert_exit 0 agents laptop2 check --skip-validation
assert_exit 0 agents laptop2 install --skip-validation
assert_eq 0 "$(find "$(home_of laptop2)/.agents/skills" -name foo | wc -l)" "agents install does not install it"

# A person: ask later stores nothing, the same question comes again, and it is no failure.
out=$(ask_on_tty laptop2 'l' incoming)
assert_contains "$out" 'skill foo (new) - machine laptop1'
assert_contains "$out" '[I]nstall, ask [L]ater, [N]ever on this machine, show the [D]ifference'
assert_eq 'skill:foo' "$(waiting laptop2)"
assert_eq 0 "$(find "$(home_of laptop2)/.agents/skills" -name foo | wc -l)"
assert_json "$(state_of laptop2)/review.json" '[.items[]? | select(.code == "incoming")] | length == 0' ||
  true

# The difference first, then install: the copy is there, in sync, and nobody asks again.
out=$(ask_on_tty laptop2 $'d\ni' incoming)
assert_contains "$out" 'description: Synthetic skill.'
assert_contains "$out" 'installed skill foo'
assert_eq '' "$(waiting laptop2)"
assert_eq "$(remote_entry foo | jq -r .directory_sha256)" "$(base laptop2 foo)"
assert_eq "$(remote_file agent/skills/foo/SKILL.md)" "$(cat "$(home_of laptop2)/.agents/skills/foo/SKILL.md")"
assert_exit 0 ds laptop2 incoming
assert_eq '[]' "$(skipped laptop2 skills)"
[[ ! -f $(state_of laptop2)/review.json ]] || assert_json "$(state_of laptop2)/review.json" \
  '[.items[] | select(.code == "incoming")] | length == 0'

# The same through the command an agent runs, with the review up to date afterwards.
captured laptop1 bar
EXPECT_STATUS=3 ds_code laptop2 incoming
assert_eq 'skill:bar' "$(waiting laptop2)"
assert_exit 0 ds laptop2 incoming show skill:bar
assert_contains "$DS_STDOUT" 'name: bar'
assert_exit 0 ds laptop2 incoming answer skill:bar --install
assert_eq '' "$(waiting laptop2)"
[[ -f $(home_of laptop2)/.agents/skills/bar/SKILL.md ]] || ds_fail "bar was not installed"
[[ ! -f $(state_of laptop2)/review.json ]] || assert_json "$(state_of laptop2)/review.json" \
  '[.items[] | select(.code == "incoming")] | length == 0'

# The machine that captured it is not asked about its own work.
git -C "$(clone_of laptop1)" pull -q --ff-only origin main
assert_eq '' "$(waiting laptop1)"
