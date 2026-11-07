# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and capture-helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# Helpers for the tests of own plugins (tests/skills-tracking). Not a test file. On top of
# capture-helpers.sh:
#
#   fake agent CLIs     claude and codex on PATH write each call to agent-calls and fail;
#                       FAKE_CODEX_LIST=FILE: `codex plugin list --json` prints FILE, and
#                       `codex plugin add SPEC` marks SPEC installed and enabled there
#   new_plugin MACHINE NAME [AGENT]
#                       a plugin as its agent lays it out, with a skill: claude in
#                       ~/.claude/skills (`claude plugin init`), codex in ~/.codex/plugins
#   plugin_dir MACHINE NAME [AGENT]
#   tool_wrote MACHINE FILE [FIXTURE]
#                       what the hook of Claude Code sees when a file tool wrote FILE
#   plugin_item MACHINE NAME JQ, plugin_base MACHINE NAME, settle_plugin MACHINE NAME [AGENT]
#   remote_plugin NAME  its own_plugins entry in the tip of the remote
# shellcheck source=tests/skills-tracking/capture-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/capture-helpers.sh"

cat >"$DS_TEST_ROOT/bin/claude" <<FAKE
#!$BASH
printf 'claude %s\n' "\$*" >>"$DS_TEST_ROOT/agent-calls"
exit 1
FAKE
cat >"$DS_TEST_ROOT/bin/codex" <<FAKE
#!$BASH
printf 'codex %s\n' "\$*" >>"$DS_TEST_ROOT/agent-calls"
if [[ -n \${FAKE_CODEX_LIST:-} && "\$*" == "plugin list --json" ]]; then
  cat "\$FAKE_CODEX_LIST"
  exit 0
fi
if [[ -n \${FAKE_CODEX_LIST:-} && \$1 == plugin && \$2 == add ]]; then
  jq --arg spec "\$3" '.installed = ([.installed[] | select(.pluginId != \$spec)]
    + [{pluginId: \$spec, name: (\$spec | split("@")[0]), marketplaceName: (\$spec | split("@")[1]),
        installed: true, enabled: true}])' "\$FAKE_CODEX_LIST" >"\$FAKE_CODEX_LIST.tmp"
  mv -- "\$FAKE_CODEX_LIST.tmp" "\$FAKE_CODEX_LIST"
  exit 0
fi
exit 1
FAKE
chmod 0755 "$DS_TEST_ROOT/bin/claude" "$DS_TEST_ROOT/bin/codex"
: >"$DS_TEST_ROOT/agent-calls"

plugin_dir() {
  case ${3:-claude} in
    claude) printf '%s\n' "$(home_of "$1")/.claude/skills/$2" ;;
    codex) printf '%s\n' "$(home_of "$1")/.codex/plugins/$2" ;;
  esac
}

new_plugin() {
  local dir manifest=.${3:-claude}-plugin
  dir=$(plugin_dir "$1" "$2" "${3:-claude}")
  mkdir -p "$dir/$manifest" "$dir/skills/$2-helper"
  printf '{\n  "name": "%s",\n  "version": "0.1.0",\n  "description": "Synthetic plugin."\n}\n' "$2" \
    >"$dir/$manifest/plugin.json"
  printf -- '---\nname: %s-helper\ndescription: Synthetic skill of a plugin.\n---\n\n# Helper\n' "$2" \
    >"$dir/skills/$2-helper/SKILL.md"
}

tool_wrote() {
  on "$1" bash -c 'sed -e "s|@HOME@|$HOME|g" -e "s|@CWD@|$PWD|g" -e "s|@SESSION@|fe058fc9|g" -e "s|@FILE@|$2|g" "$1" |
    "$3" skills hook PostToolUse --agent claude' _ "$fixtures/claude/${3:-post-tool-use-write}.json" "$2" \
    "$DS_REPO_ROOT/cli/dotsteward"
}

plugin_item() {
  local pending
  pending=$(state_of "$1")/skills/pending.json
  [[ -f $pending ]] || {
    jq -rn "{} | $3"
    return 0
  }
  jq -r --arg key "plugin:$2" ".items[\$key] // {} | $3" "$pending"
}

plugin_base() {
  jq -r --arg key "plugin:$2" '.[$key].base_sha256 // "none"' "$(state_of "$1")/skills/base.json" 2>/dev/null ||
    printf 'none\n'
}

settle_plugin() {
  find "$(plugin_dir "$1" "$2" "${3:-claude}")" -exec touch -h -d '2001-01-01' {} +
}

remote_plugin() {
  git -C "$remote" show refs/heads/main:agent/skills.lock.json |
    jq -c --arg name "$1" 'first((.own_plugins // [])[] | select(.name == $name)) // {}'
}
