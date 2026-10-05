# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Application stubs: claude, code, example-app, example-term (version and
# help), herdr (reload with recorded environment and delay), codex (plugin
# list and add), opencode (an HTTP /skill server) and pi (RPC on stdin).

ds_use_stubs claude code example-app example-term herdr codex opencode pi

# --- version and help -------------------------------------------------------
assert_eq "2.0.0 (Claude Code)" "$(claude --version)"
assert_eq "1.105.0
0000000000000000000000000000000000000000
x64" "$(code --version)"
assert_eq "example-app 1.2.3" "$(example-app --version)"
assert_eq "example-term 0.9.0" "$(example-term --version)"
assert_eq "herdr 0.9.3" "$(herdr --version)"
assert_eq "codex-cli 0.50.0" "$(codex --version)"
assert_eq "1.0.0" "$(opencode --version)"
assert_eq "0.40.0" "$(pi --version)"
assert_contains "$(example-term --help)" "Usage: example-term"
ds_stub_set claude version "2.1.0 (Claude Code)"
assert_eq "2.1.0 (Claude Code)" "$(claude --version)"
: >"$DS_CALL_LOG"
example-app open --new-window
assert_calls "example-app open --new-window"

# --- herdr --------------------------------------------------------------------
: >"$DS_CALL_LOG"
HERDR_SOCKET_PATH=/run/socket XDG_CONFIG_HOME=$HOME/.config herdr server reload-config
assert_calls "herdr server reload-config" \
  "herdr:env HOME=$HOME XDG_CONFIG_HOME=$HOME/.config HERDR_SOCKET_PATH=/run/socket"
: >"$DS_CALL_LOG"
env -u HERDR_SOCKET_PATH -u XDG_CONFIG_HOME herdr server reload-config
assert_eq "herdr:env HOME=$HOME -XDG_CONFIG_HOME -HERDR_SOCKET_PATH" "$(ds_env_of herdr)"
ds_stub_set herdr reload-exit 3
assert_exit 3 herdr server reload-config
ds_stub_set herdr reload-exit 0
ds_stub_set herdr reload-sleep 5
assert_exit 124 timeout 1 herdr server reload-config

# --- codex plugins ------------------------------------------------------------
assert_json - '.installed == []' <<<"$(codex plugin list --json)"
: >"$DS_CALL_LOG"
codex plugin add example-plugin@example-market >/dev/null
assert_calls "codex plugin add example-plugin@example-market" "codex:env -CODEX_HOME"
assert_json - '.installed[0] == {"pluginId": "example-plugin@example-market", "installed": true, "enabled": true, "version": "1.0.0"}' \
  <<<"$(codex plugin list --json)"
cache=$HOME/.codex/plugins/cache/example-market/example-plugin/1.0.0
assert_json "$cache/.codex-plugin/plugin.json" '.version == "1.0.0" and .name == "example-plugin"'
# CODEX_HOME moves the cache; version and skill directories are settable.
ds_stub_set codex plugin-version 2.0.0
ds_stub_set codex plugin-skills "alpha-skill beta-skill"
CODEX_HOME=$TMPDIR/codex-home codex plugin add other-plugin@example-market >/dev/null
other_cache=$TMPDIR/codex-home/plugins/cache/example-market/other-plugin/2.0.0
assert_json "$other_cache/.codex-plugin/plugin.json" '.version == "2.0.0"'
[[ -f $other_cache/skills/alpha-skill/SKILL.md && -f $other_cache/skills/beta-skill/SKILL.md ]] ||
  ds_fail "plugin skill directories missing"
assert_exit 1 codex plugin add not-a-spec
# A canned list replaces the recorded one.
ds_stub_set codex plugins '{"installed": [{"pluginId": "x@y", "installed": true, "enabled": false, "version": "1.0"}]}'
assert_json - '.installed[0].enabled == false' <<<"$(codex plugin list --json)"

# --- opencode serve /skill ----------------------------------------------------
mkdir -p "$HOME/.agents/skills/alpha-skill" "$HOME/.agents/skills/.system/hidden"
printf -- '---\nname: alpha-skill\ndescription: Alpha.\n---\n' >"$HOME/.agents/skills/alpha-skill/SKILL.md"
printf -- '---\nname: hidden\ndescription: Hidden.\n---\n' >"$HOME/.agents/skills/.system/hidden/SKILL.md"
# A skill linked into the root from elsewhere is reported at the link path,
# and a link back to an ancestor does not make the walk loop.
mkdir -p "$HOME/.codex/skills/linked-skill"
printf -- '---\nname: linked-skill\ndescription: Linked.\n---\n' >"$HOME/.codex/skills/linked-skill/SKILL.md"
ln -s "$HOME/.codex/skills/linked-skill" "$HOME/.agents/skills/linked-skill"
ln -s .. "$HOME/.agents/skills/alpha-skill/loop"
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
opencode serve --pure --hostname 127.0.0.1 --port "$port" >"$TMPDIR/opencode.log" 2>&1 &
server=$!
ds_defer kill "$server"
body=""
for _ in $(seq 1 100); do
  body=$(curl --noproxy '*' -fsS "http://127.0.0.1:$port/skill" 2>/dev/null) && break
  sleep 0.1
done
assert_json - 'map(.name) == ["alpha-skill", "hidden", "linked-skill"]' <<<"$body"
assert_json - '.[2].location == "'"$HOME"'/.agents/skills/linked-skill/SKILL.md"' <<<"$body"
assert_json - '.[0].location == "'"$HOME"'/.agents/skills/alpha-skill/SKILL.md"' <<<"$body"
kill "$server"
wait "$server" 2>/dev/null || true
assert_contains "$(ds_calls_of opencode)" "opencode serve --pure --hostname 127.0.0.1 --port $port"
# Modes for the probe's failure paths.
ds_stub_set opencode serve-mode exit
assert_exit 1 opencode serve --pure --hostname 127.0.0.1 --port "$port"
ds_stub_set opencode serve-mode not-list
opencode serve --hostname 127.0.0.1 --port "$port" >/dev/null 2>&1 &
server=$!
ds_defer kill "$server"
for _ in $(seq 1 100); do
  body=$(curl --noproxy '*' -fsS "http://127.0.0.1:$port/skill" 2>/dev/null) && break
  sleep 0.1
done
assert_json - 'type == "object"' <<<"$body"
kill "$server"
wait "$server" 2>/dev/null || true

# --- pi -----------------------------------------------------------------------
assert_contains "$(pi --help)" "--offline"
assert_contains "$(pi --help)" "--no-skills"
assert_contains "$(pi auth check --help)" "--json"
assert_contains "$(pi auth check --help)" "--no-refresh"
: >"$DS_CALL_LOG"
agent_dir=$TMPDIR/pi-agent
response=$(printf '{"type":"get_commands"}\n' |
  PI_OFFLINE=1 PI_CODING_AGENT_DIR=$agent_dir pi --mode rpc --no-session --no-extensions --no-prompt-templates)
assert_calls "pi --mode rpc --no-session --no-extensions --no-prompt-templates" \
  "pi:env PI_OFFLINE=1 PI_CODING_AGENT_DIR=$agent_dir"
assert_json - '.type == "response" and .command == "get_commands" and .success == true' <<<"$response"
assert_json - '[.data.commands[] | select(.source == "skill") | .name] == ["skill:alpha-skill", "skill:linked-skill"]' <<<"$response"
assert_json - '[.data.commands[] | select(.source != "skill")] | length >= 1' <<<"$response"
ds_stub_set pi rpc-mode invalid-json
response=$(printf '{"type":"get_commands"}\n' | pi --mode rpc)
if jq -e . >/dev/null 2>&1 <<<"$response"; then ds_fail "invalid-json mode produced JSON"; fi
ds_stub_set pi rpc-mode exit
assert_exit 1 pi --mode rpc </dev/null
ds_stub_set pi rpc-mode normal
ds_stub_set pi commands '[{"name": "skill:beta-skill", "source": "skill"}]'
response=$(printf '{"type":"get_commands"}\n' | pi --mode rpc)
assert_json - '.data.commands == [{"name": "skill:beta-skill", "source": "skill"}]' <<<"$response"
