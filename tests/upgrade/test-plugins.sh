# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# E33, T7-b: upgrade never updates a plugin marketplace, it looks at what updated itself. The first
# run only learns the installed trees; a changed tree is scanned; a clean scan is said; a finding is
# a review item and nothing is rolled back. autoUpdate stays what it was.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
tool_stub codex 'printf "codex-cli 1.0.0\n"'
claude_cache=$HOME/.claude/plugins/cache/example-market/example-plugin/1.0.0
codex_cache=$HOME/.codex/plugins/cache/example-market/other-plugin/1.0.0
mkdir -p "$claude_cache" "$codex_cache"
printf 'one\n' >"$claude_cache/README.md"
printf 'one\n' >"$codex_cache/README.md"
printf '{"autoUpdate": true}\n' >"$HOME/.claude/settings.json"
settings_before=$(sha256sum "$HOME/.claude/settings.json")

assert_exit 3 upgrade --tracked
assert_no_step '^scan .*plugins/cache'
scan=$DOTSTEWARD_STATE_ROOT/plugins/scan.json
assert_json "$scan" '.plugins | length == 2'

# A plugin moved by itself: its new tree is scanned where it is.
clear_log
new=$HOME/.claude/plugins/cache/example-market/example-plugin/1.1.0
mkdir -p "$new"
printf 'two\n' >"$new/README.md"
assert_exit 3 upgrade --tracked
assert_contains "$(steps '^scan .*plugins/cache')" "--tree --redact"
assert_contains "$(steps '^scan .*plugins/cache')" "$new"
assert_eq 1 "$(steps '^scan .*plugins/cache' | wc -l | tr -d ' ')" "only what changed"
assert_contains "$DS_STDOUT" "1 plugin updated itself"
last_report '.data.plugins.updated == 1'

# Unchanged: nothing to scan.
clear_log
assert_exit 3 upgrade --tracked
assert_no_step '^scan .*plugins/cache'

# A finding: named in the review, nothing removed.
clear_log
printf 'x\n' >"$codex_cache/FINDING"
assert_exit 3 upgrade --tracked
review_json '[.items[] | select(.code == "plugin-scan-finding" and (.plugin | contains("other-plugin")))] | length == 1'
[[ -e $codex_cache/FINDING ]] || ds_fail "the finding must stay where it is"

# A finding is told once for one tree, and a clean tree says nothing again.
clear_log
assert_exit 3 upgrade --tracked
assert_no_step '^scan .*plugins/cache'
review_json '[.items[] | select(.code == "plugin-scan-finding")] | length == 1'

# Never: the marketplaces, a plugin update, autoUpdate.
log=$(cat "$UP_LOG")
assert_not_contains "$log" "marketplace"
assert_not_contains "$log" "plugin update"
assert_no_step '^(claude|codex) plugin'
assert_eq "$settings_before" "$(sha256sum "$HOME/.claude/settings.json")"
