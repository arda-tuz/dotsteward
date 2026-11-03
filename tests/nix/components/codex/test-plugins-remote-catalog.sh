# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Codex lists the plugins of a remote marketplace from a remote catalog
# request, and when that request fails (the network is down for a moment)
# `codex plugin list --json` only warns and lists those plugins as missing.
# The codex plugins hook in check mode (`dotsteward agents check`, which
# `dotsteward e2e` runs) therefore reads the plugin list again when it does
# not show a plugin, up to four times, after a pause of 2, 4, 8 and 16
# seconds, and verifies the plugin once it is listed. A plugin that is still
# missing after the last read fails with the message of a missing plugin,
# and check still installs nothing.
# shellcheck source=tests/nix/components/codex/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/codex/helpers.sh"

codex_hermetic_path
ds_use_stubs codex

spec=example-plugin@example-market
warning='Warning: failed to list remote marketplace plugins: failed to send remote plugin catalog request to https://plugins.example.com/installed: error sending request'
sleep_log=$DS_TEST_ROOT/tools/sleep.log

agents() {
  codex_cli "$inst" agents "$1" --profile workstation
}

# pauses: the pauses the hook slept, on one line.
pauses() {
  if [[ -f $sleep_log ]]; then
    paste -s -d ' ' "$sleep_log"
  fi
}

# catalog_down [COUNT]: the next COUNT (default: every) `codex plugin list
# --json` calls warn that the remote catalog request failed and list no
# plugin.
catalog_down() {
  local -a times=()
  [[ -z ${1:-} ]] || times=(--times "$1")
  ds_stub_route codex 'plugin list --json' --stdout '{"installed": []}' --stderr "$warning" "${times[@]}"
}

inst=$(codex_instance remote-catalog '["x86_64-linux"]' "method = \"external\"
options = { plugins = [{ spec = \"$spec\" }] }")
codex_mirror "$inst"
mkdir -p "$HOME/.codex/skills" "$HOME/.agents/skills"
assert_exit 0 agents install
assert_contains "$DS_STDOUT" "codex plugin $spec 1.0.0 verified"

# --- the catalog request fails twice: read again, then verified ------------------------------

catalog_down 2
: >"$DS_CALL_LOG"
rm -f -- "$sleep_log"
assert_exit 0 agents check
assert_contains "$DS_STDERR" "$warning"
assert_contains "$DS_STDERR" "[dotsteward] WARNING: codex plugin $spec is not listed; reading the plugin list again in 2s"
assert_contains "$DS_STDERR" "[dotsteward] WARNING: codex plugin $spec is not listed; reading the plugin list again in 4s"
assert_contains "$DS_STDOUT" "codex plugin $spec 1.0.0 verified"
assert_call_count 3 codex 'plugin list --json'
assert_eq "2 4" "$(pauses)" "pauses before the plugin list is read again"

# --- the catalog stays down: the message of a missing plugin after the last read -------------

catalog_down
: >"$DS_CALL_LOG"
rm -f -- "$sleep_log"
before=$(codex_home_state)
assert_exit 1 agents check
assert_contains "$DS_STDERR" "[dotsteward] ERROR: codex plugin $spec is not installed and enabled; run 'dotsteward agents install --profile workstation'"
assert_contains "$DS_STDERR" "component codex hook plugins failed (exit 1)"
assert_call_count 5 codex 'plugin list --json'
assert_eq "2 4 8 16" "$(pauses)" "pauses before the plugin list is read again"
assert_call_count 0 codex 'plugin add*'
assert_eq "$before" "$(codex_home_state)" "check changes nothing"

# --- the catalog answers again: one read, no pause ---------------------------------------------

ds_stub_clear_routes codex
: >"$DS_CALL_LOG"
rm -f -- "$sleep_log"
assert_exit 0 agents check
assert_contains "$DS_STDOUT" "codex plugin $spec 1.0.0 verified"
assert_call_count 1 codex 'plugin list --json'
assert_eq "" "$(pauses)" "pauses with the plugin listed"
