# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# dotsteward context --json when sources are missing or vary: the minimal
# instance (no mirror, buffer, skills lock, flake.lock or state records),
# runtime_matches_check both ways and per platform (SPEC 4.4), the
# profiles.current fallback (D15), state.root and gate overrides from the
# environment, and the flake.lock variants of the framework upstream (D17).
# shellcheck source=tests/cli/context/helpers.sh
source "$DS_REPO_ROOT/tests/cli/context/helpers.sh"

export DOTSTEWARD_PLATFORM=linux
state=$DOTSTEWARD_STATE_ROOT

# --- Minimal instance ---------------------------------------------------------

minimal=$DS_TEST_ROOT/instances/minimal
make_minimal_instance "$minimal"
doc=$(context_json "$minimal")
printf '%s\n' "$doc" >"$DS_TEST_ROOT/minimal.json"
validate_schema "$DS_TEST_ROOT/minimal.json"

assert_eq '{"path":"'"$minimal"'","name":"minimal","remote":"git@github.com:alice/workstation.git","branch":"main","checkout":"'"$HOME"'/minimal","upstream_contribute":"fork"}' \
  "$(jq -c .instance <<<"$doc")"
# No current/profile record: the check profile (D15).
assert_eq '{"names":["main"],"current":"main","default":"main","check":"main","bootstrap":"main","modes":{"main":"fresh"}}' \
  "$(jq -c .profiles <<<"$doc")"
assert_eq '{"nix_max_jobs":5,"nix_cores":3,"min_free_gib":5,"cache_url":"https://cache.nixos.org"}' \
  "$(jq -c '.gate | del(.step_keys)' <<<"$doc")"
assert_eq '{"update_subject":"chore: update pinned tool versions","settings_subject":"chore: sync local maintained settings","upgrade_subject":"chore(dotsteward): upgrade to {version}"}' \
  "$(jq -c '.commit | del(.conventional_types)' <<<"$doc")"
assert_eq '[]' "$(jq -c .protected <<<"$doc")"
assert_eq '{"dotsteward-maintain":null,"dotsteward-update":null,"dotsteward-contribute":null}' "$(jq -c .overlays <<<"$doc")"
# No mirror: settings targets and commands are unknown, the method is the
# configured one (none here).
assert_eq '[["shell",false,null,[],[]],["herdr",false,null,[],[]],["claude-code",false,null,[],[]],["codex",false,null,[],[]],["opencode-pi",false,null,[],[]],["vscode",false,null,[],[]]]' \
  "$(jq -c '[.components[] | [.name, .enable, .method, .settings_targets, .commands]]' <<<"$doc")"
assert_eq '{"buffer_dir":"local-maintained-files","published_ref":"origin/main","target_names":[],"entry_ids":[]}' \
  "$(jq -c .settings <<<"$doc")"
assert_eq '{"hm_root":".agents/skills","instance_skill_names":[]}' "$(jq -c .skills <<<"$doc")"
assert_eq '[null,null]' "$(jq -c '[.framework.upstream, .framework.track]' <<<"$doc")"

# --- Identity -----------------------------------------------------------------

# The runtime identity matches when USER and HOME equal the check identity
# of the running platform (identity.home on Linux, identity.darwin_home on
# macOS); a trailing slash of HOME does not matter.
same=$DS_TEST_ROOT/instances/same
mkdir -p "$same"
cat >"$same/workstation.toml" <<TOML
schema_version = 1

[identity]
username = "dotsteward-test"
home = "$HOME"
darwin_home = "$DS_TEST_ROOT/darwin-home"

[instance]
remote = "git@github.com:alice/workstation.git"

[nix]
state_version = "26.05"

[profiles]
names = ["main"]
TOML
matches() {
  ds_cli --instance "$same" context --json | jq -c '.identity | [.check_home, .runtime_matches_check]'
}
assert_eq "[\"$HOME\",true]" "$(matches)"
assert_eq "[\"$HOME\",true]" "$(HOME=$HOME/ matches)"
assert_eq "[\"$HOME\",false]" "$(USER=someone-else matches)"
assert_eq "[\"$HOME\",false]" "$(HOME=$DS_TEST_ROOT matches)"
assert_eq "[\"$DS_TEST_ROOT/darwin-home\",false]" "$(DOTSTEWARD_PLATFORM=darwin matches)"
assert_eq "[\"$DS_TEST_ROOT/darwin-home\",true]" "$(DOTSTEWARD_PLATFORM=darwin HOME=$DS_TEST_ROOT/darwin-home matches)"
# Without USER the runtime user is null and nothing matches.
assert_eq '[null,false]' "$(env -u USER "$context_framework/cli/dotsteward" --instance "$same" context --json |
  jq -c '.identity | [.runtime_user, .runtime_matches_check]')"

# --- State and profiles -------------------------------------------------------

inst=$DS_TEST_ROOT/instances/workstation
make_rich_instance "$inst"
current() {
  ds_cli --instance "$inst" context --json | jq -r .profiles.current
}
assert_eq workstation "$(current)"
mkdir -p "$state/current"
printf 'fresh\n' >"$state/current/profile"
assert_eq fresh "$(current)"
# A record that names no profile of the instance (another instance's
# state, a damaged file) falls back to the check profile.
printf 'gone\n' >"$state/current/profile"
assert_eq workstation "$(current)"
: >"$state/current/profile"
assert_eq workstation "$(current)"

# state.root from the configuration, expanded with the runtime HOME.
assert_eq "$HOME/.local/state/workstation" \
  "$(env -u DOTSTEWARD_STATE_ROOT "$context_framework/cli/dotsteward" --instance "$inst" context --json | jq -r .state.root)"

# Gate values after the environment overrides (SPEC 6.1).
assert_eq '[3,5,7,"https://mirror.example.invalid"]' \
  "$(DOTSTEWARD_NIX_MAX_JOBS=3 DOTSTEWARD_NIX_CORES=5 DOTSTEWARD_MIN_FREE_GB=7 \
    DOTSTEWARD_CACHE_URL=https://mirror.example.invalid ds_cli --instance "$inst" context --json |
    jq -c '[.gate.nix_max_jobs, .gate.nix_cores, .gate.min_free_gib, .gate.cache_url]')"

# --- Framework upstream (flake.lock, D17) ----------------------------------------

upstream() {
  ds_cli --instance "$inst" context --json | jq -c '[.framework.upstream, .framework.track]'
}
assert_eq '["github:example-org/dotsteward","v1.2.0"]' "$(upstream)"
cp "$context_fixtures/locks/git.json" "$inst/flake.lock"
assert_eq '["git+ssh://git@example.invalid/team/dotsteward.git",null]' "$(upstream)"
cp "$context_fixtures/locks/none.json" "$inst/flake.lock"
assert_eq '[null,null]' "$(upstream)"
rm "$inst/flake.lock"
assert_eq '[null,null]' "$(upstream)"

# --- Mirror of another system ----------------------------------------------------

# Only the mirror of the running system is read.
rm -r "$inst/.dotsteward"
write_mirror "$inst" aarch64-darwin
assert_eq '[[],[]]' \
  "$(ds_cli --instance "$inst" context --json | jq -c '[.settings.target_names - ["example-term-state"], ([.components[].commands[]] | unique)]')"
