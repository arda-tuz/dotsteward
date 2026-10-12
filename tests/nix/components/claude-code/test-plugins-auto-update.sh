# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Marketplace auto-update in the claude-code plugins hook. Claude Code leaves
# a third-party marketplace out of its background updates unless
# extraKnownMarketplaces.NAME.autoUpdate is true in the user's settings.json
# (`claude plugin marketplace add` declares the marketplace without it). The
# hook turns it on for every marketplace a plugin entry names with
# `marketplace`, unless that entry says autoUpdate = false: install writes
# the key and keeps every other key of the file, check only verifies it.
# shellcheck source=tests/nix/components/claude-code/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/claude-code/helpers.sh"

nix_core_init

cc_hermetic_path
ds_use_stubs claude

settings=$HOME/.claude/settings.json
repo=example-org/example-market
other_repo=example-org/other-marketplace

agents() {
  cc_cli "$inst" agents "$1" --profile workstation
}

# fresh_home: no marketplace, no plugin, no settings file, an empty call log,
# and the skill layout the agents step checks before the hooks run.
fresh_home() {
  rm -rf -- "$DS_STUB_STATE/claude" "$HOME/.claude" "$HOME/.agents"
  mkdir -p "$HOME/.claude/skills" "$HOME/.agents/skills"
  : >"$DS_CALL_LOG"
}

# canned_markets: Claude Code already lists both marketplaces, with no
# declaration of them in settings.json.
canned_markets() {
  jq -cn --arg repo "$repo" --arg other "$other_repo" \
    '[{ name: "example-market", source: "github", repo: $repo, installLocation: "/home/user/.claude/plugins/marketplaces/example-market" },
      { name: "other-marketplace", source: "github", repo: $other, installLocation: "/home/user/.claude/plugins/marketplaces/other-marketplace" }]' |
    ds_stub_set claude marketplaces -
}

inst=$(cc_instance auto-update 'method = "external"
options = { plugins = [
  { spec = "alpha@example-market", marketplace = "example-org/example-market" },
  { spec = "beta@example-market", marketplace = "example-org/example-market" },
  { spec = "gamma@other-marketplace", marketplace = "example-org/other-marketplace", autoUpdate = false },
] }')
cc_mirror "$inst"

# --- install turns it on by default and off where the entry says so ------------------------

fresh_home
assert_exit 0 agents install
assert_contains "$DS_STDOUT" "claude marketplace example-market: setting autoUpdate to true in $settings"
assert_contains "$DS_STDOUT" "claude marketplace other-marketplace: setting autoUpdate to false in $settings"
assert_json "$settings" '.extraKnownMarketplaces["example-market"]
  == { source: { source: "github", repo: "example-org/example-market" }, autoUpdate: true }'
assert_json "$settings" '.extraKnownMarketplaces["other-marketplace"]
  == { source: { source: "github", repo: "example-org/other-marketplace" }, autoUpdate: false }'
assert_exit 0 agents check
assert_contains "$DS_STDOUT" "claude marketplace example-market: autoUpdate true verified"
assert_contains "$DS_STDOUT" "claude marketplace other-marketplace: autoUpdate false verified"

# A second install changes nothing: the file is not rewritten.
before=$(sha256sum "$settings")
assert_exit 0 agents install
assert_not_contains "$DS_STDOUT" "setting autoUpdate"
assert_eq "$before" "$(sha256sum "$settings")" "a second install leaves settings.json as it is"

# --- check verifies and never writes -------------------------------------------------------

# The user (or the /plugin screen) turned it off: check fails and changes
# nothing, install puts it back.
jq '.extraKnownMarketplaces["example-market"].autoUpdate = false' "$settings" >"$settings.tmp"
mv -- "$settings.tmp" "$settings"
before=$(sha256sum "$settings")
assert_exit 1 agents check
assert_contains "$DS_STDERR" "claude marketplace example-market: autoUpdate is false in $settings, expected true; run 'dotsteward agents install --profile workstation'"
assert_eq "$before" "$(sha256sum "$settings")" "check changes nothing"
assert_exit 0 agents install
assert_json "$settings" '.extraKnownMarketplaces["example-market"].autoUpdate == true'

# An entry that opted out is held to false the same way.
jq '.extraKnownMarketplaces["other-marketplace"].autoUpdate = true' "$settings" >"$settings.tmp"
mv -- "$settings.tmp" "$settings"
assert_exit 1 agents check
assert_contains "$DS_STDERR" "claude marketplace other-marketplace: autoUpdate is true in $settings, expected false"
assert_exit 0 agents install
assert_json "$settings" '.extraKnownMarketplaces["other-marketplace"].autoUpdate == false'

# Declared without the key, as `claude plugin marketplace add` leaves it.
jq 'del(.extraKnownMarketplaces["example-market"].autoUpdate)' "$settings" >"$settings.tmp"
mv -- "$settings.tmp" "$settings"
assert_exit 1 agents check
assert_contains "$DS_STDERR" "claude marketplace example-market: autoUpdate is unset in $settings, expected true"
assert_exit 0 agents install

# --- install keeps everything else in settings.json ----------------------------------------

fresh_home
jq -n '{
  theme: "example-theme",
  env: { EXAMPLE: "1" },
  extraKnownMarketplaces: {
    "example-market": { source: { source: "github", repo: "example-org/example-market" }, note: "kept" },
    "unrelated-market": { source: { source: "github", repo: "example-org/unrelated" }, autoUpdate: false }
  }
}' >"$settings"
assert_exit 0 agents install
assert_json "$settings" '.theme == "example-theme" and .env == { EXAMPLE: "1" }'
assert_json "$settings" '.extraKnownMarketplaces["example-market"].note == "kept"
  and .extraKnownMarketplaces["example-market"].autoUpdate == true'
assert_json "$settings" '.extraKnownMarketplaces["unrelated-market"]
  == { source: { source: "github", repo: "example-org/unrelated" }, autoUpdate: false }'

# A marketplace Claude Code already lists, with no settings.json yet, gets
# the file created with the declaration.
fresh_home
canned_markets
assert_exit 0 agents install
assert_json "$settings" '.extraKnownMarketplaces["example-market"].autoUpdate == true'
assert_eq 644 "$(stat -c %a "$settings")" "settings.json is created with mode 0644"

# A settings.json that is not JSON is reported, never overwritten.
fresh_home
canned_markets
printf 'not json\n' >"$settings"
for mode in check install; do
  assert_exit 1 agents "$mode"
  assert_contains "$DS_STDERR" "$settings is not valid JSON"
done
assert_eq "not json" "$(<"$settings")" "an unreadable settings.json is left alone"

# --- CLAUDE_CONFIG_DIR moves the file the same way as for Claude Code ------------------------

fresh_home
export CLAUDE_CONFIG_DIR=$DS_TEST_ROOT/claude-config
mkdir -p "$CLAUDE_CONFIG_DIR"
assert_exit 0 agents install
assert_json "$CLAUDE_CONFIG_DIR/settings.json" '.extraKnownMarketplaces["example-market"].autoUpdate == true'
assert_contains "$DS_STDOUT" "claude marketplace example-market: autoUpdate true verified"
unset CLAUDE_CONFIG_DIR
