# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# E5, no terminal: no flag means tracked, no menu, no sudo. Phase 1 goes to review.json, the rest
# runs, the analysis counts go to review.json and no question comes. The same command on a terminal
# converges: what is done stays done, the apt part happens, the key changed so E2E runs again.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
tool_stub fwupdmgr 'exit 2'
ds_dpkg_installed example-tracked 1.0
move agent_tools.codex.linux 2.0.0 download

assert_exit 3 upgrade
assert_no_step '^sudo'
assert_no_step '^apt (recover|policy|commit)'
assert_order '^pins .*apply' '^claude update' '^rebuild ' '^e2e '
review_json '[.items[] | select(.code == "sudo-required" and (.run | startswith("dotsteward upgrade")))] | length == 1'
review_json '[.items[] | select(.code == "analysis" and (.counts.apt == 1) and (.path | endswith("upgrade/analysis.json")))] | length == 1'
last_report '.data.mode == "tracked" and .exit_code == 3'
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)" "the lock file publishes without the apt part"

# --accept does not replace the terminal.
clear_log
assert_exit 3 upgrade --accept series:kernel=7.4
assert_no_step '^sudo'
assert_no_step '^apt commit'
review_json '[.items[] | select(.code == "sudo-required" and (.run | contains("--accept series:kernel=7.4")))] | length == 1'

# The same on a terminal.
clear_log
apt_answer commit '{"status": "committed", "committed": true,
  "changes": {"install": [], "upgrade": [{"name": "example-tracked", "from": "1.0", "to": "1.1"}], "remove": [], "downgrade": []},
  "items": [], "gated": {"decision": "no-move"}, "applicable": true}'
assert_exit 0 on_terminal 'Update what=1' 'Update these too=n' --
assert_order '^sudo -v' '^apt recover' '^apt policy' '^apt commit' '^sudo -k'
assert_no_step '^rebuild '
assert_order '^e2e ' # a commit that changed something runs E2E again
if [[ -e $DOTSTEWARD_STATE_ROOT/review.json ]]; then
  review_json '[.items[] | select(.code == "sudo-required")] | length == 0'
fi

# --all without a terminal: the channels of the user run, what needs sudo waits.
clear_log
apt_answer commit "$NOTHING_CHANGED"
tool_stub snap
tool_stub rustup 'case "$1" in check) printf "stable-x86_64-unknown-linux-gnu - Up to date : 1.90.0\n";; esac'
tool_stub sampletool
tool_stub flatpak
assert_exit 3 upgrade --all
assert_order '^rustup update stable' '^sampletool tool upgrade --all'
assert_no_step '^snap refresh$'
assert_no_step '^sudo'
assert_order '^flatpak update --user'
review_json '[.items[] | select(.code == "sudo-required")] | length == 1'
review_json '[.items[] | select(.code == "analysis")] | length == 0'
