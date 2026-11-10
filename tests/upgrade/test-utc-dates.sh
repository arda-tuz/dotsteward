# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# Every commit `dotsteward upgrade` makes in the instance has UTC dates (docs/privacy.md), whatever
# time zone the shell of the person has: the commit that publishes the host file and the commit of
# the writer.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
base=$(remote_oid)

move agent_tools.codex.linux 2.0.0 download
TZ=UTC-3 assert_exit 3 upgrade --tracked
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"
made=$(git -C "$up_inst" rev-list "$base..HEAD")
assert_eq 2 "$(wc -l <<<"$made" | tr -d ' ')" "the host file and the pins"
for commit in $made; do
  assert_eq "+0000 +0000" "$(git -C "$up_inst" log -1 --format='%ad %cd' --date=format:%z "$commit")" \
    "the dates of $(git -C "$up_inst" log -1 --format=%s "$commit")"
done
