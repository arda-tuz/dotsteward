# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# A red E2E that names two components, one by the pin of its official binary and one only by
# its name, holds the pins of both after a green way back, and only those: the next run would
# otherwise move the pin of the second again and go red the same way.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
holds=$DOTSTEWARD_STATE_ROOT/holds.json

move agent_tools.codex.linux 2.0.0 download
move sample.agents 6.8.0 npm
move innocent.tool 1.1.0 pypi
printf 'codex:version\nsample:sample\n' >"$UP_CONTROL/e2e-red-once"
assert_exit 3 upgrade --tracked
assert_contains "$DS_STDOUT" "agent_tools.codex.linux 2.0.0 stays back"
assert_contains "$DS_STDOUT" "sample.agents 6.8.0 stays back"
assert_json "$holds" '[.holds[].id] | sort == ["agent_tools.codex.linux", "sample.agents"]'
assert_json "$holds" '[.holds[] | select(.id == "agent_tools.codex.linux")][0].component == "codex"'
assert_json "$holds" '[.holds[] | select(.id == "sample.agents")][0].component == "sample"'
review_json '[.items[] | select(.code == "red-held") | .id] | sort == ["agent_tools.codex.linux", "sample.agents"]'
