# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub and the hooks run later and are single-quoted on purpose
# The way back protects the units of the desktop that runs also when `dotsteward upgrade` runs
# without the desktop in its own environment (over SSH, from cron or a systemd timer): the names of
# the desktop come from the user manager too (systemctl --user show-environment: XDG_CURRENT_DESKTOP,
# XDG_SESSION_DESKTOP, DESKTOP_SESSION), whose units the way back stops and restarts. When neither
# names a desktop, the way back takes back only what is clearly the framework's (dotsteward-* and
# home-manager-* units of the moved generation) and leaves every other unit as it runs, since any of
# them could be a unit of the desktop. dbus, the audio server and the portals stay protected always.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
export UP_GENERATIONS=$DS_TEST_ROOT/generations
unset XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP DESKTOP_SESSION

# The move adds a daemon of the owner, a framework unit and the shell and keyring of the desktop
# (an instance that overrides them), and changes a service of the owner and the portal.
{
  declare -f start_unit
  printf 'UP_CONTROL=%q UP_GENERATIONS=%q\n' "$UP_CONTROL" "$UP_GENERATIONS"
  cat <<'HOOK'
units=$UP_GENERATIONS/generation-$(git -C "$DOTSTEWARD_INSTANCE" rev-parse 'HEAD^{tree}')/home-files/.config/systemd/user
mkdir -p "$units"
if [[ $DOTSTEWARD_INSTANCE == */upgrade/work ]]; then
  for unit in example-daemon dotsteward-example home-manager-example otherdesk-keyring-daemon \
    org.otherdesk.Shell example-changed xdg-desktop-portal; do
    printf 'moved\n' >"$units/$unit.service"
  done
  for unit in example-daemon dotsteward-example home-manager-example otherdesk-keyring-daemon \
    org.otherdesk.Shell; do
    start_unit "$unit.service" "$unit-1"
  done
else
  for unit in example-changed xdg-desktop-portal; do
    printf 'before\n' >"$units/$unit.service"
  done
fi
HOOK
} >"$UP_CONTROL/rebuild-status-hook"

# go_back VERSION: a move of codex to VERSION, red in its E2E, and the way back.
go_back() {
  clear_log
  : >"$UP_CONTROL/user-units"
  start_unit example-changed.service changed-1
  start_unit xdg-desktop-portal.service portal-1
  move agent_tools.codex.linux "$1" download
  jq --arg to "$1" 'map(select(.id != "agent_tools.codex.linux" or .to == $to))' "$UP_CONTROL/moves" >"$UP_CONTROL/moves.new"
  mv -- "$UP_CONTROL/moves.new" "$UP_CONTROL/moves"
  printf '{"items": [{"id": "agent_tools.codex.linux", "latest": "%s", "status": "update"}]}\n' "$1" >"$UP_CONTROL/latest-rows"
  printf 'codex:version\n' >"$UP_CONTROL/e2e-red-once"
  assert_exit 3 upgrade --tracked
  assert_contains "$DS_STDOUT" "agent_tools.codex.linux $1 stays back"
}
running() {
  awk '{ print $1 }' "$UP_CONTROL/user-units" | LC_ALL=C sort | tr '\n' ' '
}

# The environment of the command names no desktop; the user manager does.
printf 'HOME=/home/example\nXDG_CURRENT_DESKTOP=ubuntu:OtherDesk\nDESKTOP_SESSION=ubuntu\n' >"$UP_CONTROL/manager-environment"
go_back 2.0.0
assert_eq "systemctl --user stop --no-pager -- dotsteward-example.service example-daemon.service home-manager-example.service" \
  "$(steps '^systemctl --user stop ')"
assert_eq "systemctl --user restart --no-pager -- example-changed.service" "$(steps '^systemctl --user restart ')"
assert_eq "example-changed.service org.otherdesk.Shell.service otherdesk-keyring-daemon.service xdg-desktop-portal.service " "$(running)" \
  "the units that run after the way back"

# Neither names a desktop: only the framework's units go back; the rest runs as it is.
printf 'HOME=/home/example\n' >"$UP_CONTROL/manager-environment"
go_back 3.0.0
assert_eq "systemctl --user stop --no-pager -- dotsteward-example.service home-manager-example.service" \
  "$(steps '^systemctl --user stop ')"
assert_no_step '^systemctl --user restart '
assert_eq "example-changed.service example-daemon.service org.otherdesk.Shell.service otherdesk-keyring-daemon.service xdg-desktop-portal.service " \
  "$(running)" "the units that run after the way back without a desktop name"
assert_contains "$DS_STDOUT" "no desktop name"
