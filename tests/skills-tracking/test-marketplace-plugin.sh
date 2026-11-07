# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and capture-helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# A plugin of Claude Code from a GitHub marketplace (design 4.7) is downloaded: the agent
# asks whether to track it on all machines, only on this one, or never. The look reads the
# files of Claude Code (installed_plugins.json at user scope, known_marketplaces.json) and
# starts no process. --all adds a [[components.claude-code.options.plugins]] table with the
# spec and the marketplace to workstation.toml on the remote, --here adds machines, --never
# lands in declined.plugins of the host file and is never asked again. A marketplace keeps
# its plugins up to date by itself: an update of a plugin that is not tracked never tracks
# it, and one of a tracked plugin changes nothing. A project-scope plugin, a plugin of a
# marketplace that is not a GitHub one and the plugins Claude Code brings itself are no
# question, and neither is anything without the files.
# shellcheck source=tests/skills-tracking/plugin-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/plugin-helpers.sh"

# The instance manages Claude Code, with one plugin tracked already.
git clone -q "$remote" "$world/edit"
cat >>"$world/edit/workstation.toml" <<'TOML'

[components.claude-code]
enable = true

[[components.claude-code.options.plugins]]
spec = "tracked-plugin@example-market"
marketplace = "example-org/example-market"
TOML
commit_instance "$world/edit"
git -C "$world/edit" push -q origin HEAD:main

new_machine a
fake_nix_mirrors a
plugins_dir=$(home_of a)/.claude/plugins
mkdir -p "$plugins_dir"

markets() {
  jq -n '{
    "example-market": {source: {source: "github", repo: "example-org/example-market"},
      installLocation: "/nowhere/example-market", lastUpdated: "2026-01-01T00:00:00.000Z", autoUpdate: true},
    "local-market": {source: {source: "directory", path: "/nowhere/local-market"},
      installLocation: "/nowhere/local-market", lastUpdated: "2026-01-01T00:00:00.000Z"}
  }' >"$plugins_dir/known_marketplaces.json"
}

# installed SPEC... : those plugins at user scope, version 1.0.<VERSION>; and a few that
# are no question.
VERSION=0
installed() {
  local spec document
  document=$(jq -n '{version: 2, plugins: {
    "project-plugin@example-market": [{scope: "project", projectPath: "/nowhere/project",
      installPath: "/nowhere/cache/project-plugin", version: "1.0.0"}],
    "local-plugin@local-market": [{scope: "user", installPath: "/nowhere/cache/local-plugin", version: "1.0.0"}],
    "synced-plugin@synced": [{scope: "user", installPath: "/nowhere/cache/synced-plugin", version: "1.0.0"}],
    "builtin-plugin@builtin": [{scope: "user", installPath: "/nowhere/cache/builtin-plugin", version: "1.0.0"}]
  }}')
  for spec in "$@"; do
    document=$(jq --arg spec "$spec" --arg version "1.0.$VERSION" --arg sha "$(printf '%040d' "$VERSION")" \
      '.plugins[$spec] = [{scope: "user", installPath: ("/nowhere/cache/" + $spec), version: $version,
        installedAt: "2026-01-01T00:00:00.000Z", lastUpdated: "2026-01-01T00:00:00.000Z", gitCommitSha: $sha}]' \
      <<<"$document")
  done
  printf '%s\n' "$document" >"$plugins_dir/installed_plugins.json"
  # A new file time, as an install by Claude Code gives it.
  touch -d "@$(($(date +%s) + VERSION))" "$plugins_dir/installed_plugins.json"
}

remote_plugins() {
  git -C "$remote" show refs/heads/main:workstation.toml |
    python3 -c 'import json, sys, tomllib; print(json.dumps(tomllib.loads(sys.stdin.read())["components"]["claude-code"]["options"]["plugins"]))'
}

told() {
  HOOK_ENV=(CLAUDE_CODE_SESSION_ATTENDED=1)
  hook_on a SessionStart session-start
  HOOK_ENV=()
}

# --- without the files of Claude Code nothing is asked --------------------------------------

assert_exit 0 ds a skills reconcile
assert_eq '{}' "$(jq -c '.items' "$(state_of a)/skills/pending.json")"
installed fetched-plugin@example-market
assert_exit 0 ds a skills reconcile
assert_eq "{}" "$(plugin_item a fetched-plugin@example-market .)" "no known_marketplaces.json: no question"
markets

# --- a plugin of a GitHub marketplace is asked about ----------------------------------------

installed fetched-plugin@example-market tracked-plugin@example-market
assert_exit 0 ds a skills reconcile
assert_eq ask "$(plugin_item a fetched-plugin@example-market .state)"
assert_eq downloaded "$(plugin_item a fetched-plugin@example-market .origin)"
assert_eq plugin "$(plugin_item a fetched-plugin@example-market .kind)"
assert_eq '[]' "$(jq -c '[.items | keys[] | select(. != "plugin:fetched-plugin@example-market")]' "$(state_of a)/skills/pending.json")" \
  "tracked, project, synced, builtin and non-GitHub plugins are no question"
told
assert_contains "$HOOK_OUT" "fetched-plugin@example-market"
assert_contains "$HOOK_OUT" "dotsteward skills track <name> --all | --here | --never"
asked=$(plugin_item a fetched-plugin@example-market .last_asked)
[[ $asked != null ]] || ds_fail "the question was recorded"

# An update by the marketplace keeps the question as it was and tracks nothing.
tip=$(remote_tip)
VERSION=1
installed fetched-plugin@example-market tracked-plugin@example-market
assert_exit 0 ds a skills reconcile
assert_eq ask "$(plugin_item a fetched-plugin@example-market .state)"
assert_eq "$asked" "$(plugin_item a fetched-plugin@example-market .last_asked)"
told
assert_not_contains "$HOOK_OUT" "fetched-plugin@example-market" "asked once a day"
ds_code a skills capture --now
assert_eq "$tip" "$(remote_tip)"

# --- --never: in the host file, never asked again, also after an update --------------------

ds_code a skills track fetched-plugin@example-market --never
assert_contains "$(remote_file hosts/a.toml)" "fetched-plugin@example-market"
assert_eq '["tracked-plugin@example-market"]' "$(remote_plugins | jq -c '[.[].spec]')"
assert_eq declined "$(plugin_item a fetched-plugin@example-market .state)"
tip=$(remote_tip)
VERSION=2
installed fetched-plugin@example-market tracked-plugin@example-market
assert_exit 0 ds a skills reconcile --full
assert_eq declined "$(plugin_item a fetched-plugin@example-market .state)"
told
assert_not_contains "$HOOK_OUT" "fetched-plugin@example-market"
ds_code a skills capture --now
assert_eq "$tip" "$(remote_tip)"
# The state of this machine gone: the host file remembers.
git -C "$(clone_of a)" pull -q --ff-only
rm -f "$(state_of a)/skills/pending.json"
assert_exit 0 ds a skills reconcile
assert_eq "{}" "$(plugin_item a fetched-plugin@example-market .)"
assert_eq '["fetched-plugin@example-market"]' "$(remote_file hosts/a.toml |
  python3 -c 'import json, sys, tomllib; print(json.dumps(tomllib.loads(sys.stdin.read())["declined"]["plugins"]))')"

# --- --all: a table of options.plugins with its marketplace ---------------------------------

VERSION=3
installed fetched-plugin@example-market tracked-plugin@example-market shared-plugin@example-market
assert_exit 0 ds a skills reconcile
assert_eq ask "$(plugin_item a shared-plugin@example-market .state)"
# Another machine has it too, and asks as well.
new_machine d
mkdir -p "$(home_of d)/.claude/plugins"
cp -- "$plugins_dir/known_marketplaces.json" "$plugins_dir/installed_plugins.json" "$(home_of d)/.claude/plugins/"
assert_exit 0 ds d skills reconcile
assert_eq ask "$(plugin_item d shared-plugin@example-market .state)"
start=$(remote_tip)
ds_code a skills track shared-plugin@example-market --all
assert_eq "$start" "$(git -C "$remote" rev-parse 'refs/heads/main^')" "one commit"
assert_eq "chore(plugins): track shared-plugin@example-market" "$(git -C "$remote" log -1 --format=%s refs/heads/main)"
assert_contains "$(git -C "$remote" log -1 --format=%B refs/heads/main)" "Dotsteward-Machine: a"
# With the mirrors generate makes of the new tree (test-marketplace-mirrors.sh).
assert_eq ".dotsteward/manifest.$fixture_system.json
workstation.toml" "$(git -C "$remote" diff-tree --no-commit-id --name-only -r refs/heads/main | LC_ALL=C sort)"
assert_json - '.[-1] == {"spec": "shared-plugin@example-market", "marketplace": "example-org/example-market"}' <<<"$(remote_plugins)"
# What the file said before stays as it was, comments included.
assert_eq "$(git -C "$remote" show "$start:workstation.toml")" \
  "$(git -C "$remote" show refs/heads/main:workstation.toml | head -n "$(git -C "$remote" show "$start:workstation.toml" | wc -l)")"
assert_eq "{}" "$(plugin_item a shared-plugin@example-market .)"
# The checkout is behind and still does not name it: no new question.
assert_exit 0 ds a skills reconcile --full
assert_eq "{}" "$(plugin_item a shared-plugin@example-market .)"
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a static
assert_exit 0 ds a skills reconcile --full
assert_eq "{}" "$(plugin_item a shared-plugin@example-market .)"
# The answer reaches the other machine with its checkout: the question there goes, with
# no further look at the files of Claude Code.
git -C "$(clone_of d)" pull -q --ff-only
assert_exit 0 ds d skills reconcile
assert_eq "{}" "$(plugin_item d shared-plugin@example-market .)"
assert_exit 0 ds d skills reconcile --full
assert_eq "{}" "$(plugin_item d shared-plugin@example-market .)"

# --- --here: only on this machine -----------------------------------------------------------

VERSION=4
installed fetched-plugin@example-market tracked-plugin@example-market shared-plugin@example-market here-plugin@example-market
assert_exit 0 ds a skills reconcile
ds_code a skills track here-plugin@example-market --here
assert_json - '.[-1] == {"spec": "here-plugin@example-market", "marketplace": "example-org/example-market", "machines": ["a"]}' \
  <<<"$(remote_plugins)"
# The machine it names is known: its host file is on the remote.
assert_contains "$(remote_file hosts/a.toml)" "schema_version"
new_machine b
assert_exit 0 ds b skills effective --json
assert_json - '.skip.plugins | index("here-plugin@example-market") != null' <<<"$DS_STDOUT"
# --own makes no sense for a plugin of a marketplace.
VERSION=5
installed fetched-plugin@example-market tracked-plugin@example-market shared-plugin@example-market here-plugin@example-market \
  other-plugin@example-market
assert_exit 0 ds a skills reconcile
EXPECT_STATUS=1 ds_code a skills track other-plugin@example-market --all --own
assert_contains "$DS_STDERR" "marketplace"
assert_eq ask "$(plugin_item a other-plugin@example-market .state)"

# --- updates of tracked plugins change nothing; an uninstalled one is no question -----------

tip=$(remote_tip)
VERSION=6
installed fetched-plugin@example-market tracked-plugin@example-market shared-plugin@example-market here-plugin@example-market
assert_exit 0 ds a skills reconcile --full
assert_eq "{}" "$(plugin_item a other-plugin@example-market .)" "uninstalled: the question goes"
for spec in tracked-plugin@example-market shared-plugin@example-market here-plugin@example-market; do
  assert_eq "{}" "$(plugin_item a "$spec" .)"
done
ds_code a skills capture --now
assert_eq "$tip" "$(remote_tip)"

# Tracking off: nothing is asked.
new_machine c
sed -i '/^tracking = true$/d' "$(clone_of c)/workstation.toml"
mkdir -p "$(home_of c)/.claude/plugins"
cp -- "$plugins_dir/known_marketplaces.json" "$plugins_dir/installed_plugins.json" "$(home_of c)/.claude/plugins/"
EXPECT_STATUS=1 ds_code c skills track fetched-plugin@example-market --all
assert_contains "$DS_STDERR" "tracking is off"

assert_eq "" "$(cat "$DS_TEST_ROOT/agent-calls")"
