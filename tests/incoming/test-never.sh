# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# Never on this machine: the answer is the intention of the machine, so it is in its host
# file in git, it holds without a network, and a reinstall under the same name finds it.
# shellcheck source=tests/incoming/helpers.sh
source "$DS_REPO_ROOT/tests/incoming/helpers.sh"

machine_up laptop1
machine_up laptop2
captured laptop1 foo
up_to_date laptop2
assert_eq 'skill:foo' "$(waiting laptop2)"

out=$(ask_on_tty laptop2 'n' incoming)
assert_contains "$out" 'skill foo: never on this machine'
assert_eq '["foo"]' "$(remote_file hosts/laptop2.toml | python3 -c 'import json,sys,tomllib; print(json.dumps(tomllib.load(sys.stdin.buffer)["declined"]["skills"]))')"
assert_contains "$(git -C "$remote" log -1 --format=%B refs/heads/main)" "Dotsteward-Machine: laptop2"
assert_eq "$(remote_tip)" "$(git -C "$(clone_of laptop2)" rev-parse HEAD)" "the checkout has the answer"
[[ -z $(git -C "$(clone_of laptop2)" status --porcelain) ]] || ds_fail "the checkout is not clean"
assert_eq '' "$(waiting laptop2)"
assert_exit 0 ds laptop2 skills effective --json
assert_eq declined "$(jq -r '.reasons["skill:foo"]' <<<"$DS_STDOUT")"
assert_exit 0 agents laptop2 install --skip-validation
[[ ! -e $(home_of laptop2)/.agents/skills/foo ]] || ds_fail "a declined skill was installed"

# A change of it is no question either.
up_to_date laptop1
edited laptop1 foo 'more text'
up_to_date laptop2
assert_eq '' "$(waiting laptop2)"

# The other machine knows nothing of it.
up_to_date laptop1
assert_eq '' "$(waiting laptop1)"

# A reinstall under the same name: a new home and state, the answer is in the tree.
rm -rf -- "$(state_of laptop2)" "$(home_of laptop2)"
mkdir -p "$(state_of laptop2)" "$(home_of laptop2)/.agents/skills" "$(home_of laptop2)/.claude/skills" "$(home_of laptop2)/.codex/skills"
assert_exit 0 agents laptop2 install --skip-validation
[[ ! -e $(home_of laptop2)/.agents/skills/foo ]] || ds_fail "a reinstall brought a declined skill back"
assert_eq '' "$(waiting laptop2)"

# Without a network: the answer holds here at once, and lands with the next run.
captured laptop1 bar
up_to_date laptop2
assert_eq 'skill:bar' "$(waiting laptop2)"
url=$(git -C "$(clone_of laptop2)" remote get-url origin)
git -C "$(clone_of laptop2)" remote set-url origin "$world/gone.git"
assert_exit 0 ds laptop2 incoming answer skill:bar --never
assert_contains "$DS_STDERR" "waits"
assert_eq '' "$(waiting laptop2)"
assert_exit 0 ds laptop2 skills effective --json
assert_eq declined "$(jq -r '.reasons["skill:bar"]' <<<"$DS_STDOUT")"
assert_not_contains "$(remote_file hosts/laptop2.toml)" '"bar"'
git -C "$(clone_of laptop2)" remote set-url origin "$url"
assert_exit 0 ds laptop2 incoming
assert_contains "$(remote_file hosts/laptop2.toml)" '"bar"'
assert_json "$(state_of laptop2)/machine/known.json" '(.never.skills // []) == []'
assert_eq '' "$(waiting laptop2)"
