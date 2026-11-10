# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and up_* variables come from the harness and tests/cli/update/helpers.sh
# shellcheck disable=SC2034 # the paths are read by the test files
# Helpers for the tests of `dotsteward upgrade` (tests/upgrade). Not a test file.
#
# UP_REAL_APT=world, set before sourcing, keeps apt-get and sudo away from the stubs for a rootless
# world of tests/apt-worlds; UP_REAL_APT=machine also keeps dpkg-query, for a disposable container
# where sudo, apt and dpkg are real. The fake apt helper is off in both.
#
# Sourcing this file sources tests/cli/update/helpers.sh, for a synthetic instance up_inst with a
# bare remote behind the fake SSH transport, and adds a world in which upgrade really runs its
# dispatcher, gate and txn publish, while the heavy commands are fakes that keep their contracts:
#   fw            a copy of the framework; rebuild, e2e, pins, static, probes and scan are the
#                 files of tests/upgrade/fakes, and the catalog holds example-app, claude-code, codex
#   UP_LOG        one line for each thing done, in order: fake commands, the fake apt helper, the
#                 tools below, "sudo ..." for each sudo call
#   UP_CONTROL    files in here switch failures and answers on: see the fakes
#   up-bin        first on PATH: the wrapper around the sudo stub, tool_stub tools; snap, flatpak,
#                 and the like are not on PATH at all
#   UP_APT        the answers of the fake apt helper, ACTION.json or ACTION-MODE.json; one package
#                 waits outside the tracked set, so a terminal gets the offer
#   bridge        the apt bridge script as `install --component` leaves it, under DS_SYSTEM_ROOT
#   systemctl     a fake of the user manager, never the real one: $UP_CONTROL/user-units holds one
#                 line "UNIT INVOCATION" per running user service; --user list-units, show (Id,
#                 ActiveState, InvocationID of the units named), stop and restart (a new
#                 invocation) read and change it, and each call goes to UP_LOG as
#                 "systemctl ARG..."; start_unit UNIT starts one
#
#   upgrade ARG...           dotsteward upgrade through the dispatcher, standard input empty and
#                            no terminal
#   on_terminal ANSWER... -- ARG...
#                            the same on a terminal of its own; each ANSWER is TEXT=REPLY: REPLY
#                            is typed when TEXT shows up
#   apt_answer ACTION JSON   the answer of the fake helper (ACTION may end in -tracked or -all); the
#                            default says nothing changed
#   steps PATTERN            the lines of UP_LOG matching the extended regular expression
#   clear_log                empties UP_LOG
#   assert_order A B...      each pattern matches a line after the match of the one before
#   assert_stdout_json FILTER  jq FILTER over the standard output of the last assert_exit is true
#   assert_no_step PATTERN   no line of UP_LOG matches
#   tool_stub NAME [SCRIPT]  a tool on PATH that logs "NAME ARG..." and then runs SCRIPT
#   review_json FILTER       jq FILTER over review.json is true
#   last_report FILTER       jq FILTER over the newest report of upgrade is true
#   move ID TO [GROUP]       the fake pins apply moves the pin ID to TO when run; adds to the list
#   name_machine NAME        machine.json as `host init` writes it, profile workstation
#   step_status NAME         the status of step NAME in the newest report
#   waiting_commit           the commit waiting for the remote, empty when none
#   work_gone                the clone of the writer is not there

# shellcheck source=tests/cli/update/helpers.sh
source "$DS_REPO_ROOT/tests/cli/update/helpers.sh"

export UP_LOG=$DS_TEST_ROOT/steps.log
export UP_CONTROL=$DS_TEST_ROOT/control
export UP_APT=$DS_TEST_ROOT/apt
if [[ -z ${UP_REAL_APT:-} ]]; then
  export DOTSTEWARD_APT_PYTHON=$DS_TEST_ROOT/fakes/apt-python
fi
UP_FAKE_APT=$DS_TEST_ROOT/fakes/apt-python
mkdir -p "$UP_CONTROL" "$UP_APT" "$DS_TEST_ROOT/fakes" "$DS_TEST_ROOT/up-bin"
: >"$UP_LOG"
cp "$DS_REPO_ROOT/tests/upgrade/fakes/apt-python" "$UP_FAKE_APT"
chmod 0755 "$UP_FAKE_APT"

# shellcheck source=tests/upgrade/isolation.sh
source "$DS_REPO_ROOT/tests/upgrade/isolation.sh"
case ${UP_REAL_APT:-} in
  machine) ds_use_stubs nix curl gh ;;
  world) ds_use_stubs nix curl gh dpkg-query ;;
  *) ds_use_stubs nix curl gh sudo apt-get dpkg-query ;;
esac
export PATH=$DS_TEST_ROOT/up-bin:$PATH
serve_cache

fw=$DS_TEST_ROOT/framework
mkdir -p "$fw/modules/components/example-app" "$fw/modules/components/claude-code" "$fw/modules/components/codex"
cp -R "$DS_REPO_ROOT/cli" "$DS_REPO_ROOT/schema" "$DS_REPO_ROOT/VERSION" "$DS_REPO_ROOT/privacy" "$fw/"
find "$fw/cli" -name __pycache__ -prune -exec rm -rf {} +
for fake in rebuild e2e pins static probes scan; do
  cp "$DS_REPO_ROOT/tests/upgrade/fakes/$fake.sh" "$fw/cli/commands/$fake.sh"
  chmod 0755 "$fw/cli/commands/$fake.sh"
done

# The network as a test switches it: $UP_CONTROL/network-down ends it at any moment.
cat >"$DS_TEST_ROOT/up-bin/ssh-switch" <<SWITCH
#!$BASH
[[ ! -e "$UP_CONTROL/network-down" ]] || { printf 'ssh: connect to host github.com port 22: Network is unreachable\n' >&2; exit 255; }
exec "$GIT_SSH_COMMAND" "\$@"
SWITCH
chmod 0755 "$DS_TEST_ROOT/up-bin/ssh-switch"
export GIT_SSH_COMMAND=$DS_TEST_ROOT/up-bin/ssh-switch

# The instance: a deb component, the agents, a manifest mirror. The system is the host's own.
system=$(python3 -c 'import platform; print({"x86_64": "x86_64", "aarch64": "aarch64", "arm64": "aarch64"}[platform.machine()])')-linux
set_toml nix systems "[\"$system\"]"
cat >>"$up_inst/workstation.toml" <<'TOML'

[components.example-app]
enable = true
method = "deb"
track = ["example-tracked-too"]

[components.claude-code]
enable = true
method = "official-binary"

[components.codex]
enable = true
method = "official-binary"
TOML
mkdir -p "$up_inst/.dotsteward"
mirror=$up_inst/.dotsteward/manifest.$system.json
jq -n --arg system "$system" '{
  schema_version: 1, system: $system, platform: "linux", update_allowlist: [],
  components: [
    {name: "example-app", method: "deb", profiles: null, platforms: ["linux"],
     install: {packageNames: ["example-tracked"], apt: ["example-tracked-lib"]}},
    {name: "other-profile-app", method: "deb", profiles: ["another"], platforms: ["linux"],
     install: {packageNames: ["example-other-profile"]}},
    {name: "claude-code", method: "official-binary", profiles: null, platforms: ["linux"], install: {},
     self_update: {command: ["claude", "update"], version: ["claude", "--version"]}},
    {name: "codex", method: "official-binary", profiles: null, platforms: ["linux"],
     install: {pin: "agent_tools.codex.linux", dest: "~/.local/bin/codex",
               companions: [{pin: "agent_tools.codex-helper.linux", file: "codex-helper"}]}}
  ],
  checks: {commands: [{component: "codex", command: "codex"}, {component: "core", command: "git"}]}
}' >"$mirror"
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "chore: add the components"
git -C "$up_inst" push -q origin HEAD:main

apt_answer() {
  printf '%s\n' "$2" >"$UP_APT/$1.json"
}

NOTHING_CHANGED='{"status": "nothing", "committed": false, "changes": {"install": [], "upgrade": [], "remove": [], "downgrade": []}, "items": [], "gated": {"decision": "no-move"}, "applicable": false}'
apt_answer recover '{"recovery": {"ran": false, "clean": true}, "items": []}'
apt_answer policy '{"policy": {"changed": false}, "items": []}'
apt_answer commit "$NOTHING_CHANGED"
apt_answer plan "$NOTHING_CHANGED"
apt_answer analysis '{"available": true, "count": 1, "packages": [{"name": "example-untracked", "current": "1", "candidate": "2", "origin": "noble-updates", "phased": false}], "kernels": 2, "boot_free_mib": 900, "boot_low": false}'

# The bridge script `install --component` leaves on a machine with bridged packages.
bridge=$DS_SYSTEM_ROOT/usr/local/lib/dotsteward/apt-bridge.sh
install_bridge() {
  mkdir -p "$(dirname "$bridge")"
  printf 'printf "bridge %%s\\n" "$*" >>"%s"\n' "$UP_LOG" >"$bridge"
}

# Every sudo call goes to the log, next to what it does.
if [[ -z ${UP_REAL_APT:-} ]]; then
  ds_stub_set sudo env UP_LOG
  sudo_stub=$DS_REPO_ROOT/tests/lib/stubs/sudo
else
  sudo_stub=$(type -P sudo || true)
fi
if [[ -n $sudo_stub ]]; then
  cat >"$DS_TEST_ROOT/up-bin/sudo" <<SUDO
#!$BASH
printf 'sudo %s\n' "\$*" >>"$UP_LOG"
exec "$sudo_stub" "\$@"
SUDO
  chmod 0755 "$DS_TEST_ROOT/up-bin/sudo"
fi

upgrade() {
  "$fw/cli/dotsteward" --instance "$up_inst" upgrade "$@" </dev/null
}

: >"$UP_CONTROL/user-units"
cat >"$DS_TEST_ROOT/up-bin/systemctl" <<SYSTEMCTL
#!$BASH
set -euo pipefail
printf 'systemctl %s\n' "\$*" >>"$UP_LOG"
units=$UP_CONTROL/user-units
[[ \${1:-} == --user ]] || { printf 'Failed to connect to bus: Access denied\n' >&2; exit 1; }
shift
operation=\$1
shift
names=()
for word in "\$@"; do
  [[ \$word == -* ]] || names+=("\$word")
done
case \$operation in
  list-units)
    while read -r unit invocation; do
      printf '%s loaded active running %s\n' "\$unit" "\$unit"
    done <"\$units"
    ;;
  show)
    for name in \${names[@]+"\${names[@]}"}; do
      [[ \$name == Id || \$name == InvocationID ]] && continue
      invocation=\$(awk -v unit="\$name" '\$1 == unit { print \$2 }' "\$units")
      state=active
      [[ -n \$invocation ]] || state=inactive
      printf 'Id=%s\nActiveState=%s\nInvocationID=%s\n\n' "\$name" "\$state" "\$invocation"
    done
    ;;
  stop)
    for name in "\${names[@]}"; do
      awk -v unit="\$name" '\$1 != unit' "\$units" >"\$units.new"
      mv -- "\$units.new" "\$units"
    done
    ;;
  restart)
    for name in "\${names[@]}"; do
      awk -v unit="\$name" -v now="\$RANDOM\$RANDOM" '\$1 == unit { \$2 = now } { print }' "\$units" >"\$units.new"
      mv -- "\$units.new" "\$units"
    done
    ;;
  *) exit 1 ;;
esac
SYSTEMCTL
chmod 0755 "$DS_TEST_ROOT/up-bin/systemctl"

# start_unit UNIT [INVOCATION]: UNIT runs now, with a new invocation.
start_unit() {
  awk -v unit="$1" '$1 != unit' "$UP_CONTROL/user-units" >"$UP_CONTROL/user-units.new"
  printf '%s %s\n' "$1" "${2:-$RANDOM$RANDOM}" >>"$UP_CONTROL/user-units.new"
  mv -- "$UP_CONTROL/user-units.new" "$UP_CONTROL/user-units"
}

# declare_tool NAME CHECK UPDATE [SKIP_PROVIDERS]: a table of [[upgrade.tools]] in the instance,
# committed and published.
declare_tool() {
  {
    printf "\n[[upgrade.tools]]\nname = '%s'\ncheck = '''%s'''\nupdate = '''%s'''\n" "$1" "$2" "$3"
    if (($# == 4)); then
      printf "skip_providers = '''%s'''\n" "$4"
    fi
  } >>"$up_inst/workstation.toml"
  git -C "$up_inst" add workstation.toml
  git -C "$up_inst" commit -q -m "chore(upgrade): declare $1"
  git -C "$up_inst" push -q origin HEAD:main
}

on_terminal() {
  local answers=()
  while (($#)) && [[ $1 != -- ]]; do
    answers+=(--answer "$1")
    shift
  done
  shift
  python3 "$DS_REPO_ROOT/tests/upgrade/terminal.py" ${answers[@]+"${answers[@]}"} -- \
    "$fw/cli/dotsteward" --instance "$up_inst" upgrade "$@"
}

steps() {
  grep -E -- "$1" "$UP_LOG" || true
}

clear_log() {
  : >"$UP_LOG"
}

assert_order() {
  local previous=0 line pattern
  for pattern in "$@"; do
    line=$(tail -n +"$((previous + 1))" "$UP_LOG" | grep -n -E -m 1 -- "$pattern" | cut -d: -f1 || true)
    [[ -n $line ]] || ds_fail "no step after line $previous matches [$pattern]: $(<"$UP_LOG")"
    previous=$((previous + line))
  done
}

assert_no_step() {
  if grep -q -E -- "$1" "$UP_LOG"; then
    ds_fail "a step matches [$1]: $(grep -E -- "$1" "$UP_LOG")"
  fi
}

tool_stub() {
  local name=$1 script=${2:-}
  cat >"$DS_TEST_ROOT/up-bin/$name" <<STUB
#!$BASH
printf '%s %s\n' "$name" "\$*" >>"$UP_LOG"
$script
STUB
  chmod 0755 "$DS_TEST_ROOT/up-bin/$name"
}

assert_stdout_json() {
  printf '%s' "$DS_STDOUT" >"$DS_TEST_ROOT/stdout.json"
  assert_json "$DS_TEST_ROOT/stdout.json" "$1"
}

review_json() {
  assert_json "$DOTSTEWARD_STATE_ROOT/review.json" "$1"
}

newest_report() {
  # The report with the highest sequence.
  local file best=-1 number newest=''
  for file in "$DOTSTEWARD_STATE_ROOT"/runs/upgrade/*.json; do
    number=$(jq -r .sequence "$file")
    if ((number > best)); then
      best=$number
      newest=$file
    fi
  done
  printf '%s\n' "$newest"
}

last_report() {
  assert_json "$(newest_report)" "$1"
}

step_status() {
  jq -r --arg name "$1" '[.steps[] | select(.name == $name) | .status] | last // "none"' "$(newest_report)"
}

waiting_commit() {
  git -C "$up_inst" rev-parse --verify --quiet refs/dotsteward/upgrade/waiting || true
}

work_gone() {
  [[ ! -e $DOTSTEWARD_STATE_ROOT/upgrade/work ]] || ds_fail "the clone of the writer is still there"
}

move() {
  local list=$UP_CONTROL/moves
  [[ -e $list ]] || printf '[]\n' >"$list"
  jq --arg id "$1" --arg to "$2" --arg group "${3:-flake}" '. + [{id: $id, from: "0", to: $to, group: $group}]' "$list" >"$list.new"
  mv -- "$list.new" "$list"
}

name_machine() {
  mkdir -p "$DOTSTEWARD_STATE_ROOT"
  jq -n --arg name "$1" --arg system "$system" '{
    schema_version: 1, name: $name, machine_key: "00112233445566778899aabbccddeeff",
    named_at: "2026-01-01T00:00:00Z",
    host: {system: $system, profile: "workstation", platform: "ubuntu-24.04", tags: []}
  }' >"$DOTSTEWARD_STATE_ROOT/machine.json"
}

# A machine with a name, so upgrade knows its profile. The host file reaches the remote through
# the real `host publish`, the first thing a run does.
name_machine example-host
