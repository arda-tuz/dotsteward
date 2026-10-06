# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# dotsteward context --json (SPEC 6.5) on a rich instance: every section of
# the document, with its values taken from workstation.toml, the runtime
# environment, the state records, the settings buffer, the skills lock, the
# .dotsteward manifest mirror of the running system and flake.lock.
# shellcheck source=tests/cli/context/helpers.sh
source "$DS_REPO_ROOT/tests/cli/context/helpers.sh"

export DOTSTEWARD_PLATFORM=linux
inst=$DS_TEST_ROOT/instances/workstation
make_rich_instance "$inst"
state=$DOTSTEWARD_STATE_ROOT
write_state "$state"
system=$(runtime_system)

doc=$(context_json "$inst")
printf '%s\n' "$doc" >"$DS_TEST_ROOT/context.json"

section() {
  jq -cS ".$1" <<<"$doc"
}

expect() {
  assert_eq "$(jq -cS . <<<"$2")" "$(section "$1")" "$1"
}

# One JSON document, keys in the order of SPEC 6.5.
assert_eq 1 "$(jq -s length "$DS_TEST_ROOT/context.json")"
assert_eq '["schema_version","instance","identity","state","profiles","gate","commit","protected","overlays","components","settings","skills","framework","platform"]' \
  "$(jq -c keys_unsorted <<<"$doc")"
assert_eq 1 "$(section schema_version)"

expect instance "$(jq -n --arg path "$inst" --arg checkout "$HOME/src/workstation" '{
  path: $path, name: "workstation", remote: "git@github.com:alice/workstation.git",
  branch: "trunk", checkout: $checkout, upstream_contribute: "owner"}')"

# The check identity is [identity]; the runtime identity is USER and HOME
# (SPEC 4.4).
expect identity "$(jq -n --arg home "$HOME" '{
  check_username: "alice", check_home: "/home/alice",
  runtime_user: "dotsteward-test", runtime_home: $home, runtime_matches_check: false}')"

# DOTSTEWARD_STATE_ROOT overrides state.root; the gate records live below
# update/.
expect state "$(jq -n --arg root "$state" '{
  root: $root, memo: "\($root)/update/validation.json", log: "\($root)/update/validate.log",
  candidate: "\($root)/update/candidate.json", validation: "\($root)/update/validation.json"}')"

# current comes from <state>/current/profile.
expect profiles '{"names":["workstation","fresh"],"current":"fresh","default":"workstation","check":"workstation","bootstrap":"fresh","modes":{"workstation":"adopt","fresh":"fresh"}}'

expect gate '{"nix_max_jobs":4,"nix_cores":8,"min_free_gib":10,"cache_url":"https://cache.example.invalid","step_keys":["preflight","static","pins","flake-check","cli-probes"]}'

expect commit '{"update_subject":"chore: refresh pins","settings_subject":"chore: sync local maintained settings","upgrade_subject":"chore(dotsteward): upgrade to {version}","conventional_types":["feat","fix","perf","refactor","docs","chore","test","build","ci","style","revert"]}'

# Paths only, never the digests.
expect protected '["agent/AGENTS.md","home/AGENTS.md"]'
assert_not_contains "$doc" e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855

# Every framework skill has a key: the configured overlay, the default
# agent/overlays/<skill>.md when it exists, else null.
expect overlays '{"dotsteward-maintain":"agent/overlays/maintain.md","dotsteward-update":"agent/overlays/dotsteward-update.md","dotsteward-contribute":null}'

# Every configured component in components.order (catalog order, then
# instance names); method from the configuration for the running platform,
# else from the mirror; settings targets and commands from the mirror.
expect components '[
  {"name":"shell","enable":true,"source":"catalog","method":"nix","profiles":null,"settings_targets":[],"commands":["zsh","starship"]},
  {"name":"herdr","enable":true,"source":"catalog","method":"official-binary","profiles":["workstation"],"settings_targets":[],"commands":["herdr"]},
  {"name":"claude-code","enable":false,"source":"catalog","method":null,"profiles":null,"settings_targets":[],"commands":[]},
  {"name":"codex","enable":true,"source":"catalog","method":"external","profiles":null,"settings_targets":["codex-config"],"commands":["codex"]},
  {"name":"opencode-pi","enable":false,"source":"catalog","method":null,"profiles":null,"settings_targets":[],"commands":[]},
  {"name":"vscode","enable":true,"source":"catalog","method":"deb","profiles":null,"settings_targets":["vscode-settings"],"commands":["code"]},
  {"name":"example-term","enable":true,"source":"instance","method":"official-binary","profiles":null,"settings_targets":["example-term-config"],"commands":["example-term"]}
]'

# Target names: the mirror's component targets and the buffer's own
# targets; entry ids in buffer order; never a value, key or path of an entry.
expect settings '{"buffer_dir":"settings-buffer","published_ref":"origin/trunk","target_names":["codex-config","example-term-config","example-term-state","vscode-settings"],"entry_ids":["codex-model","term-theme","term-font"]}'
assert_not_contains "$doc" sentinel-value
assert_not_contains "$doc" '"theme"'
assert_not_contains "$doc" example-term/state.json

# Instance skills: the skills lock and the mirror's home-managed skills,
# without the framework skills.
expect skills '{"hm_root":".codex/skills","instance_skill_names":["example-local","example-notes","example-review"]}'

# framework: the running framework's version, rev and narHash (as
# `dotsteward version` reports them), and the upstream and the tracked ref
# of the dotsteward input in flake.lock (D17).
version=$(<"$context_framework/VERSION")
rev=$(ds_cli version | sed -n 's/^rev: //p')
nar=$(ds_cli version | sed -n 's/^narHash: //p')
expect framework "$(jq -n --arg version "$version" --arg rev "$rev" --arg nar "$nar" '{
  version: $version,
  rev: (if $rev == "unknown" then null else $rev end),
  narHash: (if $nar == "unknown" then null else $nar end),
  upstream: "github:example-org/dotsteward", track: "v1.2.0"}')"

expect platform "$(jq -n --arg system "$system" '{
  system: $system, name: "linux",
  fast_path: {os_id: "ubuntu", os_version: "24.04", architecture: "x86_64", desktop_contains: "example", detectors: []}}')"

validate_schema "$DS_TEST_ROOT/context.json"

# The document is the same from any working directory with --instance, and
# with DOTSTEWARD_INSTANCE.
assert_eq "$doc" "$(cd "$DS_TEST_ROOT" && ds_cli --instance "$inst" context --json)"
assert_eq "$doc" "$(cd "$DS_TEST_ROOT" && DOTSTEWARD_INSTANCE=$inst ds_cli context --json)"
