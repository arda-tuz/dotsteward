# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub and the hooks run later and are single-quoted on purpose
# The way back after a red E2E also takes back what the moved generation started: a user service
# that it started is stopped, one that it restarted is restarted, so it runs what the generation
# from before has; a service the rebuild back restarted itself, or one nobody touched, is left as
# it is. Otherwise a daemon of the moved generation stays and turns the E2E of the way back red,
# and the run neither holds the pin nor leaves the machine green.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'

start_unit example-quiet.service quiet-1
start_unit example-restarted.service restarted-1
start_unit example-switched.service switched-1
# The rebuild of the move starts one service and restarts one; the rebuild back restarts another.
{
  declare -f start_unit
  printf 'UP_CONTROL=%q\n' "$UP_CONTROL"
  cat <<'HOOK'
if [[ $DOTSTEWARD_INSTANCE == */upgrade/work ]]; then
  start_unit example-daemon.service daemon-1
  start_unit example-restarted.service restarted-2
else
  start_unit example-switched.service switched-2
fi
HOOK
} >"$UP_CONTROL/rebuild-status-hook"

move agent_tools.codex.linux 2.0.0 download
printf 'codex:version\n' >"$UP_CONTROL/e2e-red-once"
assert_exit 3 upgrade --tracked
assert_order '^rebuild .*root=.*/upgrade/work' '^e2e .*root=.*/upgrade/work' "^rebuild .*root=$up_inst\$" \
  '^systemctl --user (stop|restart) ' "^e2e .*root=$up_inst\$"
assert_eq 1 "$(steps '^systemctl --user stop ' | wc -l | tr -d ' ')"
assert_contains "$(steps '^systemctl --user stop ')" "example-daemon.service"
assert_eq 1 "$(steps '^systemctl --user restart ' | wc -l | tr -d ' ')"
assert_contains "$(steps '^systemctl --user restart ')" "example-restarted.service"
units=$(<"$UP_CONTROL/user-units")
assert_not_contains "$units" "example-daemon.service"
assert_contains "$units" "example-quiet.service quiet-1"
assert_contains "$units" "example-switched.service switched-2"
assert_not_contains "$units" "restarted-2"
assert_contains "$DS_STDOUT" "agent_tools.codex.linux 2.0.0 stays back"
