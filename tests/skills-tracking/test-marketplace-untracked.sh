# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and capture-helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# A plugin of a marketplace answered with --all and taken out of options.plugins again later
# (by hand, or on another machine) is no longer tracked, and this machine asks about it
# again, once the checkout has that change: it never stays silent for ever, and it never
# turns tracked by itself. While the checkout is behind the answer, nothing is asked.
# shellcheck source=tests/skills-tracking/plugin-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/plugin-helpers.sh"

git clone -q "$remote" "$world/edit"
printf '\n[components.claude-code]\nenable = true\n' >>"$world/edit/workstation.toml"
commit_instance "$world/edit"
git -C "$world/edit" push -q origin HEAD:main

new_machine a
plugins_dir=$(home_of a)/.claude/plugins
mkdir -p "$plugins_dir"
jq -n '{"example-market": {source: {source: "github", repo: "example-org/example-market"},
  installLocation: "/nowhere/example-market", lastUpdated: "2026-01-01T00:00:00.000Z"}}' \
  >"$plugins_dir/known_marketplaces.json"
installed() {
  jq -n --arg version "$1" '{version: 2, plugins: {"kept-plugin@example-market": [{scope: "user",
    installPath: "/nowhere/cache/kept-plugin", version: $version}]}}' >"$plugins_dir/installed_plugins.json"
  touch -d "@$(($(date +%s) + ${2:-0}))" "$plugins_dir/installed_plugins.json"
}
marker() {
  jq -c '.["plugin:kept-plugin@example-market"] // null' "$(state_of a)/skills/base.json"
}
remote_specs() {
  git -C "$remote" show refs/heads/main:workstation.toml |
    python3 -c 'import json, sys, tomllib
plugins = tomllib.loads(sys.stdin.read())["components"]["claude-code"].get("options", {}).get("plugins", [])
print(json.dumps([entry["spec"] for entry in plugins]))'
}

installed 1.0.0
assert_exit 0 ds a skills reconcile
assert_eq ask "$(plugin_item a kept-plugin@example-market .state)"
ds_code a skills track kept-plugin@example-market --all
assert_eq '["kept-plugin@example-market"]' "$(remote_specs)"
assert_json - '.tracked == "marketplace"' <<<"$(marker)"
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a skills reconcile --full
assert_eq "{}" "$(plugin_item a kept-plugin@example-market .)"

# --- the table goes again, on another machine ----------------------------------------------

git -C "$world/edit" pull -q --ff-only
python3 - "$world/edit/workstation.toml" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = re.sub(r'\n\[\[components\.claude-code\.options\.plugins\]\]\nspec = "kept-plugin@example-market"\n[^\[]*', "\n", text)
open(path, "w", encoding="utf-8").write(text)
PY
commit_instance "$world/edit"
git -C "$world/edit" push -q origin HEAD:main
assert_eq '[]' "$(remote_specs)"
tip=$(remote_tip)
# The checkout of a is behind that: nothing is asked yet.
assert_exit 0 ds a skills reconcile --full
assert_eq "{}" "$(plugin_item a kept-plugin@example-market .)"
assert_json - '.tracked == "marketplace"' <<<"$(marker)"
# With it, a asks again, without a look forced and without a change of the plugin files.
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a skills reconcile
assert_eq ask "$(plugin_item a kept-plugin@example-market .state)"
assert_eq untracked "$(plugin_item a kept-plugin@example-market .reason)"
assert_eq null "$(marker)"
HOOK_ENV=(CLAUDE_CODE_SESSION_ATTENDED=1)
hook_on a SessionStart session-start
HOOK_ENV=()
assert_contains "$HOOK_OUT" "kept-plugin@example-market"
# An update of it tracks nothing, and the question stays as it was.
installed 1.1.0 5
assert_exit 0 ds a skills reconcile
assert_eq ask "$(plugin_item a kept-plugin@example-market .state)"
ds_code a skills capture --now
assert_eq "$tip" "$(remote_tip)"
assert_eq '[]' "$(remote_specs)"
# --never ends it for this machine; asked no more.
ds_code a skills track kept-plugin@example-market --never
assert_eq declined "$(plugin_item a kept-plugin@example-market .state)"
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a skills reconcile --full
assert_eq declined "$(plugin_item a kept-plugin@example-market .state)"
