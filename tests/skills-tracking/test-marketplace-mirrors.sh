# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and plugin-helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# The answer --all (or --here) about a plugin of a marketplace changes workstation.toml, and
# the manifest mirror carries the component options, so the same commit must carry the
# mirrors `dotsteward generate` makes of the new tree: otherwise every gate after it is red
# (.dotsteward/manifest.<system>.json is stale). The commit is built in the worktree of the
# capture, with generate run by the CLI the tree pins, and goes out on the maintain ref. A
# failed evaluation publishes nothing. Nix runs only for `skills track` (and `skills
# retry`), never from a hook or a detached capture. A stub nix answers the evaluation from
# the tree it is given; tests/nix/components/claude-code proves the same with a real one.
# shellcheck source=tests/skills-tracking/plugin-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/plugin-helpers.sh"

git clone -q "$remote" "$world/edit"
printf '\n[components.claude-code]\nenable = true\n' >>"$world/edit/workstation.toml"
commit_instance "$world/edit"
git -C "$world/edit" push -q origin HEAD:main

new_machine a
mirror=.dotsteward/manifest.$fixture_system.json
# nix eval --json ... ROOT#dotstewardMirrors: the manifest of ROOT with the plugin specs of
# its workstation.toml, as the real evaluation puts them into the component options.
mkdir -p "$(home_of a)/.nix-profile/bin"
cat >"$(home_of a)/.nix-profile/bin/nix" <<NIX
#!$BASH
printf 'nix %s\n' "\$*" >>"$DS_TEST_ROOT/nix-calls"
for argument in "\$@"; do
  case \$argument in
    *'#dotstewardMirrors')
      [[ ! -e $DS_TEST_ROOT/nix-fails ]] || { printf 'error: assertion failed\n' >&2; exit 1; }
      exec python3 - "\${argument%#dotstewardMirrors}" "$mirror" <<'PY'
import json, sys, tomllib
root, mirror = sys.argv[1], sys.argv[2]
config = tomllib.load(open(f"{root}/workstation.toml", "rb"))
plugins = config.get("components", {}).get("claude-code", {}).get("options", {}).get("plugins", [])
manifest = json.load(open(f"{root}/{mirror}"))
manifest["claude_code_plugins"] = plugins
print(json.dumps({mirror.split("/")[-1]: json.dumps(manifest, indent=2) + "\n"}))
PY
      ;;
  esac
done
exit 1
NIX
chmod 0755 "$(home_of a)/.nix-profile/bin/nix"
: >"$DS_TEST_ROOT/nix-calls"

plugins_dir=$(home_of a)/.claude/plugins
mkdir -p "$plugins_dir"
jq -n '{"example-market": {source: {source: "github", repo: "example-org/example-market"},
  installLocation: "/nowhere/example-market", lastUpdated: "2026-01-01T00:00:00.000Z"}}' \
  >"$plugins_dir/known_marketplaces.json"
jq -n '{version: 2, plugins: {
  "first-plugin@example-market": [{scope: "user", installPath: "/nowhere/cache/first", version: "1.0.0"}],
  "second-plugin@example-market": [{scope: "user", installPath: "/nowhere/cache/second", version: "1.0.0"}]}}' \
  >"$plugins_dir/installed_plugins.json"
assert_exit 0 ds a skills reconcile
assert_eq ask "$(plugin_item a first-plugin@example-market .state)"

# --- a hook or a detached capture never runs Nix: the answer waits for skills track --------

ds_code a skills track first-plugin@example-market --all --no-capture
start=$(remote_tip)
ds_code a skills capture --now
assert_eq "$start" "$(remote_tip)"
assert_eq "" "$(cat "$DS_TEST_ROOT/nix-calls")"
assert_eq capture "$(plugin_item a first-plugin@example-market .state)"

# --- skills track: the table and the mirrors of the new tree, in one commit -----------------

ds_code a skills track first-plugin@example-market --all
assert_eq "$start" "$(git -C "$remote" rev-parse 'refs/heads/main^')" "one commit"
assert_eq "chore(plugins): track first-plugin@example-market" "$(git -C "$remote" log -1 --format=%s refs/heads/main)"
assert_eq "$mirror
workstation.toml" "$(git -C "$remote" diff-tree --no-commit-id --name-only -r refs/heads/main | LC_ALL=C sort)"
assert_json - '.claude_code_plugins == [{"spec": "first-plugin@example-market", "marketplace": "example-org/example-market"}]' \
  <<<"$(remote_file "$mirror")"
# The evaluation ran on the worktree of the capture, never on the checkout.
assert_contains "$(cat "$DS_TEST_ROOT/nix-calls")" "$(state_of a)/skills/worktree#dotstewardMirrors"
assert_not_contains "$(cat "$DS_TEST_ROOT/nix-calls")" "$(clone_of a)#"
# It went out on the maintain ref.
git -C "$(clone_of a)" rev-parse --verify --quiet refs/dotsteward/maintain/tip >/dev/null ||
  ds_fail "the commit is published with the maintain scope"
assert_eq "{}" "$(plugin_item a first-plugin@example-market .)"
# The mirror of the remote is what generate makes of its tree.
git -C "$(clone_of a)" pull -q --ff-only
cp -- "$(clone_of a)/$mirror" "$DS_TEST_ROOT/mirror-before"
assert_exit 0 ds a generate
cmp -s "$DS_TEST_ROOT/mirror-before" "$(clone_of a)/$mirror" || ds_fail "the published mirror is current"
assert_eq "" "$(git -C "$(clone_of a)" status --porcelain)"

# --- a failed evaluation: nothing is published, the item says why -------------------------

: >"$DS_TEST_ROOT/nix-fails"
tip=$(remote_tip)
EXPECT_STATUS=1 ds_code a skills track second-plugin@example-market --here
assert_eq "$tip" "$(remote_tip)"
assert_eq blocked "$(plugin_item a second-plugin@example-market .state)"
assert_eq generate-failed "$(plugin_item a second-plugin@example-market .reason)"
rm -f -- "$DS_TEST_ROOT/nix-fails"
ds_code a skills retry second-plugin@example-market
assert_json - '.[-1].machines == ["a"]' <<<"$(remote_file "$mirror" | jq -c .claude_code_plugins)"
assert_eq "{}" "$(plugin_item a second-plugin@example-market .)"
