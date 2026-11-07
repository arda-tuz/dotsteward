# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and helpers.sh
# shellcheck disable=SC2016 # commands for bash -c are single-quoted on purpose
# A hook of skill tracking can neither stall nor fail an agent: whatever the
# state of the machine, the command in the agent's configuration exits 0 and
# prints nothing, also when the CLI is missing, broken or exits 1, 2 or 127. It
# ends at once with DOTSTEWARD_HOOKS_OFF=1 and in a subagent, and a hook without
# a change starts no process and imports nothing that could.
# shellcheck source=tests/skills-tracking/helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/helpers.sh"

own_skill alpha
install_hooks claude
AGENT_ENV=(CLAUDE_CODE_SESSION_ATTENDED=1 CLAUDE_CODE_ENTRYPOINT=cli)
context=$HOME/.config/dotsteward/hook-context.json

# assert_silent AGENT EVENT FIXTURE [FILE]: exit 0, nothing on either stream.
assert_silent() {
  agent_event "$@"
  assert_eq "" "$EVENT_OUT" "$2 prints nothing"
  assert_eq "" "$EVENT_ERR" "$2 is silent on standard error"
}

# all_events: every event of the Claude Code configuration.
all_events() {
  assert_silent claude SessionStart session-start
  assert_silent claude PostToolUse post-tool-use-write "$HOME/.agents/skills/alpha/SKILL.md"
  assert_silent claude Stop stop
  assert_silent claude SessionEnd session-end
}

# --- the text in the configuration -------------------------------------------

for event in SessionStart PostToolUse Stop SessionEnd; do
  assert_eq "[ -x \"\$HOME/.nix-profile/bin/dotsteward\" ] && \"\$HOME/.nix-profile/bin/dotsteward\" skills hook $event --agent claude 2>/dev/null; exit 0" \
    "$(hook_text claude "$event")"
done

# --- DOTSTEWARD_HOOKS_OFF: nothing happens at all ------------------------------

cp -a "$(vendored alpha)" "$HOME/.agents/skills/created-by-hand"
sed -i 's/^name: alpha$/name: created-by-hand/' "$HOME/.agents/skills/created-by-hand/SKILL.md"
rm -f "$ss/pending.json"
AGENT_ENV=(DOTSTEWARD_HOOKS_OFF=1 CLAUDE_CODE_SESSION_ATTENDED=1)
all_events
[[ ! -e $ss/pending.json ]] || ds_fail "DOTSTEWARD_HOOKS_OFF writes nothing"
[[ ! -e $ss/deadline ]] || ds_fail "DOTSTEWARD_HOOKS_OFF arms nothing"
rm -rf "$HOME/.agents/skills/created-by-hand"
AGENT_ENV=(CLAUDE_CODE_SESSION_ATTENDED=1 CLAUDE_CODE_ENTRYPOINT=cli)

# --- a subagent: at most evidence, never a question, a sleeper or a block ------

mkdir -p "$HOME/.claude/skills/written-by-subagent"
printf -- '---\nname: written-by-subagent\n---\n' >"$HOME/.claude/skills/written-by-subagent/SKILL.md"
assert_silent claude PostToolUse post-tool-use-subagent "$HOME/.claude/skills/written-by-subagent/SKILL.md"
assert_json "$ss/pending.json" '.items["skill:written-by-subagent"].evidence.tool == "Write"'
[[ ! -e $ss/deadline ]] || ds_fail "a subagent arms no sleeper"
before=$(sha256sum "$ss/pending.json")
text=$(hook_text claude Stop)
payload claude stop-subagent >"$DS_TEST_ROOT/stop-subagent.json"
assert_eq "" "$(sh -c "$text" <"$DS_TEST_ROOT/stop-subagent.json")"
assert_eq "$before" "$(sha256sum "$ss/pending.json")" "a subagent's stop leaves the state alone"
rm -rf "$HOME/.claude/skills/written-by-subagent" "$ss/pending.json"

# --- whatever is wrong with the machine, the agent never hears of it -------------

# No context: tracking was never switched on here.
mv "$context" "$context.saved"
all_events
mv "$context.saved" "$context"
# A broken context, a broken lock, broken state files.
cp "$context" "$context.saved"
printf 'not json\n' >"$context"
all_events
mv "$context.saved" "$context"
cp "$agents_lock" "$agents_lock.saved"
printf 'not json\n' >"$agents_lock"
all_events
mv "$agents_lock.saved" "$agents_lock"
mkdir -p "$ss"
printf 'not json\n' >"$ss/pending.json"
printf '[]\n' >"$ss/base.json"
all_events
# The state directory is missing, then cannot be made. The sleepers of these events end
# here: what names them goes with the state.
# replace_state [TEXT]: the state goes, and a file with TEXT takes its place when TEXT is
# given. What the last events started detached may still be on its way and make the
# directory again, so an attempt that meets it is made again.
replace_state() {
  local tries
  for ((tries = 0; tries < 300; tries++)); do
    _kill_sleepers
    if { rm -rf "$state" && { (($# == 0)) || printf '%s\n' "$1" >"$state"; }; } 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  ds_fail "the state directory keeps coming back"
}
replace_state
all_events
replace_state 'not a directory'
all_events
rm -f "$state"
# A context that names a place nobody can write.
mkdir -p "$DS_TEST_ROOT/locked"
chmod 0500 "$DS_TEST_ROOT/locked"
jq --arg root "$DS_TEST_ROOT/locked/state" '.state_root = $root' "$context" >"$context.tmp"
mv "$context" "$context.saved"
mv "$context.tmp" "$context"
all_events
mv "$context.saved" "$context"
chmod 0700 "$DS_TEST_ROOT/locked"
# A read-only home.
mkdir -p "$state"
chmod -R a-w "$HOME" "$state"
all_events
chmod -R u+w "$HOME" "$state"
# Input the hook cannot read as a payload, and arguments it does not know.
cli=$HOME/.nix-profile/bin/dotsteward
for input in '' 'not json' '[]' '{"tool_input": 3}' '{"tool_input": {"file_path": 3}, "cwd": []}'; do
  for event in SessionStart PostToolUse Stop SessionEnd; do
    assert_exit 0 bash -c '"$2" skills hook "$3" --agent claude <<<"$1"' _ "$input" "$cli" "$event"
    assert_eq "" "$DS_STDOUT"
  done
done
# An agent that never closes its pipe does not keep the hook.
mkfifo "$DS_TEST_ROOT/open-pipe"
exec 9<>"$DS_TEST_ROOT/open-pipe"
assert_exit 0 timeout 30 "$cli" skills hook Stop --agent claude <"$DS_TEST_ROOT/open-pipe"
exec 9<&-
assert_exit 0 bash -c '"$1" skills hook </dev/null' _ "$cli"
assert_exit 0 bash -c '"$1" skills hook Nonsense --agent claude </dev/null' _ "$cli"
assert_exit 0 bash -c '"$1" skills hook Stop --agent nonsense </dev/null' _ "$cli"
assert_exit 0 bash -c '"$1" skills hook Stop --unknown-flag extra </dev/null' _ "$cli"
assert_eq "" "$DS_STDOUT"

# --- a CLI that fails: the command in the configuration still exits 0 ------------

saved_cli=$HOME/.nix-profile/bin/dotsteward.saved
mv "$cli" "$saved_cli"
for code in 1 2 127; do
  printf '#!%s\nprintf "usage: dotsteward: error\\n" >&2\nexit %s\n' "$BASH" "$code" >"$cli"
  chmod 0755 "$cli"
  all_events
done
# Not executable, then missing altogether, as during a profile switch.
chmod 0644 "$cli"
all_events
rm -f "$cli"
all_events
mv "$saved_cli" "$cli"

# --- no change: no process, no network, nothing imported that could start one ----

trace=$DS_TEST_ROOT/trace
mkdir -p "$trace"
# Files of an age: what changed two seconds ago still gets a look.
find "$HOME/.agents/skills" -exec touch -h -d '2001-01-01' {} +
assert_silent claude Stop stop
assert_silent claude SessionStart session-start
pending_before=$(sha256sum "$ss/pending.json")
# The interpreter itself: a shim on PATH would find this wrapper again.
real_python=$(python3 -c 'import sys; print(sys.executable)')
cat >"$trace/python3" <<WRAP
#!$BASH
printf 'python3\n' >>"$trace/calls"
exec "$real_python" -X importtime "\$@" 2>>"$trace/imports"
WRAP
chmod 0755 "$trace/python3"
for tool in git jq find sha256sum curl ssh gh nix flock sleep setsid nohup notify-send claude codex; do
  printf '#!%s\nprintf "%%s\\n" "%s $*" >>"%s/calls"\nexit 127\n' "$BASH" "$tool" "$trace" >"$trace/$tool"
  chmod 0755 "$trace/$tool"
done
AGENT_ENV=(CLAUDE_CODE_SESSION_ATTENDED=1 CLAUDE_CODE_ENTRYPOINT=cli "PATH=$trace:$PATH")
assert_silent claude Stop stop
assert_silent claude SessionStart session-start
assert_silent claude PostToolUse post-tool-use-write "$DS_TEST_ROOT/work/elsewhere/SKILL.md"
assert_silent claude SessionEnd session-end
assert_eq $'python3\npython3\npython3\npython3' "$(cat "$trace/calls")" "no process but the hook itself"
for module in subprocess socket pathlib tomllib dotsteward_cli.config dotsteward_cli.locks argparse; do
  if grep -Eq "\| +$module\$" "$trace/imports"; then
    ds_fail "the path without a change imports $module"
  fi
done
assert_eq "$pending_before" "$(sha256sum "$ss/pending.json")" "no change, no write"
[[ ! -e $ss/deadline ]] || ds_fail "no change arms no sleeper"
AGENT_ENV=(CLAUDE_CODE_SESSION_ATTENDED=1 CLAUDE_CODE_ENTRYPOINT=cli)
