# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# E29 through upgrade: what another machine changed is asked before the sudo window, on a terminal
# one item at a time with the machine named; without one the run goes on, the checkout moves
# and it ends in 3 with the question in the review. A component that was accepted makes a rebuild,
# on a tree that is already active.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude
name_machine laptop2
digest() {
  bash -c 'source "$1/cli/lib/lib.sh"; directory_sha256 "$2"' _ "$DS_REPO_ROOT" "$1"
}

# Another machine commits.
elsewhere=$DS_TEST_ROOT/elsewhere
git clone -q "$up_bare" "$elsewhere"
git -C "$elsewhere" config user.name dotsteward-test
git -C "$elsewhere" config user.email dotsteward-test@example.invalid
publish_elsewhere() {
  git -C "$elsewhere" add -A
  git -C "$elsewhere" commit -q -m $'feat: something\n\nDotsteward-Machine: laptop1'
  git -C "$elsewhere" pull -q --rebase origin main
  git -C "$elsewhere" push -q origin HEAD:main
}
skill_elsewhere() {
  local dir=$elsewhere/agent/skills/$1 lock=$elsewhere/agent/skills.lock.json
  mkdir -p "$dir"
  [[ -f $lock ]] || printf '{"schema_version": "1.0", "skills": []}\n' >"$lock"
  printf -- '---\nname: %s\ndescription: Synthetic skill.\n---\n\n# %s\n' "$1" "$1" >"$dir/SKILL.md"
  jq --arg name "$1" --arg digest "$(digest "$dir")" --arg skill "$(sha256sum "$dir/SKILL.md" | cut -d' ' -f1)" \
    '.skills += [{name: $name, directory: $name, revision: "same-as-instance-checkout", skill_sha256: $skill, directory_sha256: $digest}]' \
    "$lock" >"$lock.new"
  mv -- "$lock.new" "$lock"
}

# The first run on a machine asks nothing: what it holds is what it knows.
assert_exit 3 upgrade --tracked
review_json '[.items[] | select(.code == "incoming")] | length == 0'

skill_elsewhere foo
publish_elsewhere
tip=$(remote_oid)

# No terminal: the run goes on and asks nothing, the checkout moved, the question is in the review.
clear_log
assert_exit 3 upgrade --tracked
assert_eq "$tip" "$(git -C "$up_inst" rev-parse HEAD)"
review_json '[.items[] | select(.code == "incoming" and .id == "skill:foo" and .by == "laptop1")] | length == 1'
[[ ! -e $HOME/.agents/skills/foo ]] || ds_fail "installed without an answer"
assert_order '^e2e '

# A terminal: the question comes before the sudo window, and ask later is no failure.
clear_log
out=$(on_terminal 'skill foo (new) - machine laptop1=l' 'Update these too?=n' -- --tracked) || true
assert_contains "$out" 'skill foo (new) - machine laptop1'
[[ ! -e $HOME/.agents/skills/foo ]] || ds_fail "ask later installed it"

# Install lands it at once, and upgrade goes on.
clear_log
out=$(on_terminal 'skill foo (new) - machine laptop1=i' 'Update these too?=n' -- --tracked) || true
assert_contains "$out" 'installed skill foo'
[[ -f $HOME/.agents/skills/foo/SKILL.md ]] || ds_fail "install did not land it"
assert_not_contains "$(jq -c '[.items[]? | select(.code == "incoming")]' "$DOTSTEWARD_STATE_ROOT/review.json")" 'skill:foo'

# Never on this machine: the host file on the remote, and the publish of this run starts from there.
skill_elsewhere bar
publish_elsewhere
out=$(on_terminal 'skill bar (new) - machine laptop1=n' 'Update these too?=n' -- --tracked) || true
assert_contains "$out" 'skill bar: never on this machine'
git -C "$up_bare" show refs/heads/main:hosts/laptop2.toml | grep -q '"bar"' || ds_fail "the answer is not on the remote"
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"

# A new component: its question, then a rebuild of the tree that is active already, for the new tags.
git -C "$elsewhere" pull -q --ff-only origin main
mkdir -p "$elsewhere/components/example-tool"
printf '{ ... }: { }\n' >"$elsewhere/components/example-tool/default.nix"
printf '\n[components.example-tool]\nenable = true\n' >>"$elsewhere/workstation.toml"
publish_elsewhere
assert_exit 3 upgrade --tracked
review_json '[.items[] | select(.code == "incoming" and .id == "component:example-tool")] | length == 1'
activation=$DOTSTEWARD_STATE_ROOT/current/activation.json
jq --arg tags "stale" '. + {tags_sha256: $tags}' "$activation" >"$activation.new"
mv -- "$activation.new" "$activation"
clear_log
out=$(on_terminal 'component example-tool (new) - machine laptop1=i' 'Update these too?=n' -- --tracked) || true
assert_contains "$out" 'component example-tool: the next'
assert_order '^rebuild --profile workstation --switch'

# What the writer of upgrade commits leaves with the name of this machine, like every commit of
# `txn publish`, and the checkout follows that commit, not the one before the name.
clear_log
move agent_tools.codex.linux 2.0.0 download
assert_exit 3 upgrade --tracked
tip=$(remote_oid)
assert_eq "$tip" "$(git -C "$up_inst" rev-parse HEAD)"
assert_contains "$(git -C "$up_bare" log -1 --format=%B refs/heads/main)" 'Dotsteward-Machine: laptop2'
[[ -z $(git -C "$up_inst" status --porcelain) ]] || ds_fail "the checkout is not clean"
