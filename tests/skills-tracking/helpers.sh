# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and tests/agents/helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# Helpers for the tests of skill tracking (tests/skills-tracking). Not a test
# file. On top of the synthetic instance of tests/agents/helpers.sh:
#
#   ds_cli ARG...      dotsteward --instance <instance> ARG...
#   tracking_on        [skills] tracking = true in workstation.toml
#   install_hooks AGENT...
#                      `skills hooks install --agent AGENT`, tracking on
#   own_skill NAME     an own skill: vendored, in the lock, copied to
#                      ~/.agents/skills, in sync after `agents install`
#   lock_digest NAME   the lock's directory digest of NAME
#   payload AGENT NAME [FILE]
#                      the recorded payload fixtures/AGENT/NAME.json with its
#                      placeholders filled in (@FILE@ from FILE)
#   agent_event AGENT EVENT NAME [FILE]
#                      what the agent does for EVENT: runs the command its
#                      configuration holds for EVENT with the payload on
#                      standard input and the variables of AGENT_ENV, like the
#                      agent; sets EVENT_OUT, EVENT_ERR and EVENT_STATUS
#   pending_state NAME the state of skill:NAME in pending.json, or none
#   wait_for FILE PATTERN
#                      waits until the file holds a line matching PATTERN
#   wait_captures N    waits for what hooks started: N captures run by `--now` are in
#                      capture.log, and all of them have ended
#   capture_runs       how many capture runs capture.log records
#   sleepers           how many sleepers capture.log records

# shellcheck source=tests/agents/helpers.sh
source "$DS_REPO_ROOT/tests/agents/helpers.sh"

state=$DS_TEST_ROOT/state
ss=$state/skills
export DOTSTEWARD_STATE_ROOT=$state
fixtures=$DS_REPO_ROOT/tests/skills-tracking/fixtures
own_revision=same-as-instance-checkout
session_id=fe058fc9-0000-4000-8000-000000000001
AGENT_ENV=()

mkdir -p "$HOME/.nix-profile/bin" "$HOME/.agents/skills" "$HOME/.claude/skills" "$HOME/.codex/skills"
cat >"$HOME/.nix-profile/bin/dotsteward" <<CLI
#!$BASH
exec "$agents_fw/cli/dotsteward" "\$@"
CLI
chmod 0755 "$HOME/.nix-profile/bin/dotsteward"

ds_cli() {
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" "$@" </dev/null
}

# Sleepers the test leaves behind end with it.
_kill_sleepers() {
  local pid
  [[ -f $ss/capture.log ]] || return 0
  while read -r pid; do
    [[ -z $pid ]] || kill -9 "$pid" 2>/dev/null || true
  done < <(sed -n 's/^[^ ]* sleeper pid //p' "$ss/capture.log")
}
ds_defer _kill_sleepers

tracking_on() {
  grep -q '^tracking = true' "$agents_inst/workstation.toml" ||
    sed -i 's/^\[skills\]$/[skills]\ntracking = true/' "$agents_inst/workstation.toml"
}

install_hooks() {
  local agent
  tracking_on
  for agent in "$@"; do
    assert_exit 0 ds_cli skills hooks install --agent "$agent"
  done
}

own_skill() {
  lock_add "$1" --revision "$own_revision"
  cp -a "$(vendored "$1")" "$HOME/.agents/skills/$1"
  assert_exit 0 run_agents install
}

lock_digest() {
  jq -r --arg name "$1" 'first(.skills[] | select(.name == $name)) | .directory_sha256' "$agents_lock"
}

payload() {
  local agent=$1 name=$2 file=${3:-}
  sed -e "s|@HOME@|$HOME|g" -e "s|@CWD@|${EVENT_CWD:-$DS_TEST_ROOT/work}|g" \
    -e "s|@SESSION@|${EVENT_SESSION:-$session_id}|g" -e "s|@FILE@|$file|g" "$fixtures/$agent/$name.json"
}

# hook_text AGENT EVENT: the command the configuration of AGENT holds for EVENT.
hook_text() {
  local file
  case $1 in
    claude) file=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json ;;
    codex) file=${CODEX_HOME:-$HOME/.codex}/hooks.json ;;
    *) ds_fail "hook_text: unknown agent $1" ;;
  esac
  jq -r --arg event "$2" '[.hooks[$event][]?.hooks[]?.command | select(contains("skills hook"))] | first // empty' "$file"
}

agent_event() {
  local agent=$1 event=$2 name=$3 file=${4:-} text in_file out_file err_file
  text=$(hook_text "$agent" "$event")
  [[ -n $text ]] || ds_fail "agent_event: no hook for $event in the configuration of $agent"
  in_file=$(mktemp "$DS_TEST_ROOT/event.XXXXXX")
  out_file=$(mktemp "$DS_TEST_ROOT/event.XXXXXX")
  err_file=$(mktemp "$DS_TEST_ROOT/event.XXXXXX")
  payload "$agent" "$name" "$file" >"$in_file"
  EVENT_STATUS=0
  env "${AGENT_ENV[@]}" sh -c "$text" <"$in_file" >"$out_file" 2>"$err_file" || EVENT_STATUS=$?
  # shellcheck disable=SC2034 # read by the tests
  EVENT_OUT=$(<"$out_file")
  EVENT_ERR=$(<"$err_file")
  rm -f -- "$in_file" "$out_file" "$err_file"
  [[ $EVENT_STATUS == 0 ]] || ds_fail "the hook for $event exited $EVENT_STATUS; stderr [$EVENT_ERR]"
}

pending_state() {
  jq -r --arg key "skill:$1" '.items[$key].state // "none"' "$ss/pending.json" 2>/dev/null || printf 'none\n'
}

wait_for() {
  local tries=0
  until [[ -f $1 ]] && grep -q -- "$2" "$1"; do
    tries=$((tries + 1))
    ((tries < 3000)) || ds_fail "no line matching [$2] in $1 after 60 seconds"
    sleep 0.02
  done
}

wait_captures() {
  local tries=0 pid
  until (($(grep -c ' capture pid ' "$ss/capture.log" 2>/dev/null || true) >= $1)); do
    tries=$((tries + 1))
    ((tries < 3000)) || ds_fail "fewer than $1 captures started after 60 seconds"
    sleep 0.02
  done
  while read -r pid; do
    until ! _process_lives "$pid"; do
      tries=$((tries + 1))
      ((tries < 9000)) || ds_fail "the capture $pid has not ended after 3 minutes"
      sleep 0.02
    done
  done < <(sed -n 's/^[^ ]* capture pid //p' "$ss/capture.log")
}

_process_lives() {
  [[ -r /proc/$1/stat ]] || return 1
  [[ $(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1) != Z ]]
}

capture_runs() {
  [[ -f $ss/capture.log ]] || {
    printf '0\n'
    return 0
  }
  grep -c ' run$' "$ss/capture.log" || true
}

sleepers() {
  [[ -f $ss/capture.log ]] || {
    printf '0\n'
    return 0
  }
  grep -c ' sleeper ' "$ss/capture.log" || true
}
