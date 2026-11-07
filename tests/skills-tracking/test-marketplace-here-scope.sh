# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and plugin-helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# --here about a plugin of a marketplace tracks it for this machine only. Another machine
# with the same plugin is not tracked by it, so it is asked (review-c1 S4-M3), also when it
# asked before the answer came. Its own answer edits the table instead of adding a second
# one with the same spec, which the evaluation refuses: --here adds it to machines, --all
# takes machines away.
# shellcheck source=tests/skills-tracking/plugin-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/plugin-helpers.sh"

git clone -q "$remote" "$world/edit"
printf '\n[components.claude-code]\nenable = true\n' >>"$world/edit/workstation.toml"
commit_instance "$world/edit"
git -C "$world/edit" push -q origin HEAD:main

put_files() {
  local dir
  dir=$(home_of "$1")/.claude/plugins
  mkdir -p "$dir"
  jq -n '{"example-market": {source: {source: "github", repo: "example-org/example-market"}}}' \
    >"$dir/known_marketplaces.json"
  jq -n '{version: 2, plugins: {"here-plugin@example-market": [{scope: "user", installPath: "/nowhere", version: "1.0.0"}]}}' \
    >"$dir/installed_plugins.json"
}
remote_tables() {
  git -C "$remote" show refs/heads/main:workstation.toml |
    python3 -c 'import json, sys, tomllib
print(json.dumps(tomllib.loads(sys.stdin.read())["components"]["claude-code"].get("options", {}).get("plugins", [])))'
}

new_machine a
fake_nix_mirrors a
put_files a
# c asks before a answers.
new_machine c
fake_nix_mirrors c
put_files c
assert_exit 0 ds c skills reconcile
assert_eq ask "$(plugin_item c here-plugin@example-market .state)"

assert_exit 0 ds a skills reconcile
ds_code a skills track here-plugin@example-market --here
assert_json - '. == [{"spec": "here-plugin@example-market", "marketplace": "example-org/example-market", "machines": ["a"]}]' \
  <<<"$(remote_tables)"

# b was never asked: it is now, its copy is not tracked by a's answer.
new_machine b
fake_nix_mirrors b
put_files b
assert_exit 0 ds b skills reconcile --full
assert_eq ask "$(plugin_item b here-plugin@example-market .state)"
assert_exit 0 ds b skills effective --json
assert_json - '.skip.plugins | index("here-plugin@example-market") != null' <<<"$DS_STDOUT"
# c's question stays when its checkout gets a's answer.
git -C "$(clone_of c)" pull -q --ff-only
assert_exit 0 ds c skills reconcile --full
assert_eq ask "$(plugin_item c here-plugin@example-market .state)"
# a is not asked again.
assert_exit 0 ds a skills reconcile --full
assert_eq "{}" "$(plugin_item a here-plugin@example-market .)"

# --here on b joins the machines of the same table.
ds_code b skills track here-plugin@example-market --here
assert_json - '. == [{"spec": "here-plugin@example-market", "marketplace": "example-org/example-market", "machines": ["a", "b"]}]' \
  <<<"$(remote_tables)"
assert_eq "{}" "$(plugin_item b here-plugin@example-market .)"
# --all on c makes it a table for every machine.
git -C "$(clone_of c)" pull -q --ff-only
ds_code c skills track here-plugin@example-market --all
assert_json - '. == [{"spec": "here-plugin@example-market", "marketplace": "example-org/example-market"}]' <<<"$(remote_tables)"
git -C "$(clone_of b)" pull -q --ff-only
assert_exit 0 ds b skills effective --json
assert_json - '.skip.plugins | index("here-plugin@example-market") == null' <<<"$DS_STDOUT"
