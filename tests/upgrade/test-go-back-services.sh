# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub and the hooks run later and are single-quoted on purpose
# The way back takes back only what the moved generation brought: of the user services whose unit
# files are in a generation (home-files/.config/systemd/user, what Home Manager manages), one that
# only the moved generation has is stopped, and one whose unit file the moved generation changed is
# restarted, unless the rebuild back restarted it already. Nothing else is touched: not a service
# the owner or D-Bus started or restarted meanwhile, not a session service even when a generation
# names it (dbus, the session manager, the audio server), and no record of an earlier run.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
export UP_GENERATIONS=$DS_TEST_ROOT/generations

start_unit dbus.service bus-1
start_unit pipewire.service pw-1
start_unit example-changed.service changed-1
start_unit example-same.service same-1
start_unit example-switched.service switched-1
start_unit exampledesk-session-manager.service session-1
# An older release left a snapshot of the services of an earlier run: it is never read.
mkdir -p "$DOTSTEWARD_STATE_ROOT/rollback"
printf '{"services": {"dbus.service": "bus-0", "exampledesk-session-manager.service": "session-0", "pipewire.service": "pw-0"}}\n' \
  >"$DOTSTEWARD_STATE_ROOT/rollback/services.json"

# The rebuilds lay out the units of their generation and do what an activation does: the move
# starts its new service and restarts what it changed; the rebuild back restarts one it changed back.
{
  declare -f start_unit
  printf 'UP_CONTROL=%q UP_GENERATIONS=%q\n' "$UP_CONTROL" "$UP_GENERATIONS"
  cat <<'HOOK'
units=$UP_GENERATIONS/generation-$(git -C "$DOTSTEWARD_INSTANCE" rev-parse 'HEAD^{tree}')/home-files/.config/systemd/user
mkdir -p "$units"
printf 'same\n' >"$units/example-same.service"
if [[ $DOTSTEWARD_INSTANCE == */upgrade/work ]]; then
  for unit in example-daemon example-changed example-switched dbus exampledesk-session-manager pipewire; do
    printf 'moved\n' >"$units/$unit.service"
  done
  start_unit example-daemon.service daemon-1
  start_unit example-changed.service changed-2
  start_unit example-switched.service switched-2
  start_unit dbus.service bus-2
else
  for unit in example-changed example-switched dbus exampledesk-session-manager pipewire; do
    printf 'before\n' >"$units/$unit.service"
  done
  start_unit example-switched.service switched-3
fi
HOOK
} >"$UP_CONTROL/rebuild-status-hook"
# While the E2E of the move runs, the owner opens a terminal and restarts the audio server.
{
  declare -f start_unit
  printf 'UP_CONTROL=%q\n' "$UP_CONTROL"
  cat <<'HOOK'
if [[ $DOTSTEWARD_INSTANCE == */upgrade/work ]]; then
  start_unit exampledesk-terminal-server.service term-1
  start_unit pipewire.service pw-2
fi
HOOK
} >"$UP_CONTROL/e2e-hook"

move agent_tools.codex.linux 2.0.0 download
printf 'codex:version\n' >"$UP_CONTROL/e2e-red-once"
assert_exit 3 upgrade --tracked
assert_contains "$DS_STDOUT" "agent_tools.codex.linux 2.0.0 stays back"
assert_order '^rebuild .*root=.*/upgrade/work' '^e2e .*root=.*/upgrade/work' "^rebuild .*root=$up_inst\$" \
  '^systemctl --user stop ' "^e2e .*root=$up_inst\$"
assert_eq "systemctl --user stop --no-pager -- example-daemon.service" "$(steps '^systemctl --user stop ')"
assert_eq "systemctl --user restart --no-pager -- example-changed.service" "$(steps '^systemctl --user restart ')"
assert_no_step '^systemctl --user list-units'
units=$(<"$UP_CONTROL/user-units")
assert_not_contains "$units" "example-daemon.service"
assert_not_contains "$units" "changed-2"
for left in "dbus.service bus-2" "pipewire.service pw-2" "exampledesk-terminal-server.service term-1" \
  "exampledesk-session-manager.service session-1" "example-same.service same-1" "example-switched.service switched-3"; do
  assert_contains "$units" "$left"
done

# Without generations that hold units, nothing is touched at all.
clear_log
unset UP_GENERATIONS
rm -f -- "$UP_CONTROL/rebuild-status-hook" "$UP_CONTROL/e2e-hook"
move agent_tools.codex.linux 3.0.0 download
jq 'map(select(.id != "agent_tools.codex.linux" or .to == "3.0.0"))' "$UP_CONTROL/moves" >"$UP_CONTROL/moves.new"
mv -- "$UP_CONTROL/moves.new" "$UP_CONTROL/moves"
printf '{"items": [{"id": "agent_tools.codex.linux", "latest": "3.0.0", "status": "update"}]}\n' >"$UP_CONTROL/latest-rows"
printf 'codex:version\n' >"$UP_CONTROL/e2e-red-once"
assert_exit 3 upgrade --tracked
assert_no_step '^systemctl --user (stop|restart) '
