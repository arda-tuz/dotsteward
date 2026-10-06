#!/usr/bin/env bash
# The plugins hook of the codex catalog component (agentsPost; SPEC 3.5,
# 8.1, 8.4). It runs with the hook environment of `dotsteward agents
# install|check` and reads the plugin list from [components.codex] options
# of the instance's workstation.toml:
#
#   [[components.codex.options.plugins]]          # one table per plugin
#   spec = "NAME@MARKETPLACE"
#   minimumAt = "<versions.lock.json path>"       # optional
#   requiredSkillDirectories = ["<dir>", ...]     # optional
#
# install (DOTSTEWARD_CHECK_ONLY=0) runs `codex plugin add SPEC` for a plugin
# that `codex plugin list --json` does not show installed and enabled. Both
# modes then verify every plugin:
#   - it is listed installed and enabled, with a plain version string;
#   - its directory (the listed local source path, else
#     ${CODEX_HOME:-~/.codex}/plugins/cache/<marketplace>/<name>/<version>)
#     holds .codex-plugin/plugin.json with the listed version;
#   - the version is at least the lock value at minimumAt (a version string,
#     or an entry with minimum_version or version); a newer plugin passes,
#     an older one fails and is never upgraded silently;
#   - skills/<dir>/SKILL.md exists for every required skill directory.
# The first problem ends the hook with exit status 1.
set -Eeuo pipefail

[[ -n ${DOTSTEWARD_LIB:-} && -n ${DOTSTEWARD_INSTANCE:-} ]] || {
  printf '[dotsteward] ERROR: the codex plugins hook runs from dotsteward agents (DOTSTEWARD_LIB and DOTSTEWARD_INSTANCE are not set)\n' >&2
  exit 1
}

# shellcheck source=cli/lib/lib.sh
source "$DOTSTEWARD_LIB/lib.sh"
# shellcheck source=cli/lib/config.sh
source "$DOTSTEWARD_LIB/config.sh"
# shellcheck source=cli/lib/methods.sh
source "$DOTSTEWARD_LIB/methods.sh"

config_load "$DOTSTEWARD_INSTANCE"

component=${DOTSTEWARD_COMPONENT:-codex}
check_only=${DOTSTEWARD_CHECK_ONLY:-0}
profile=${DOTSTEWARD_PROFILE:-$DS_PROFILES_DEFAULT}
lock_name=${DS_PINS_VERSIONS_LOCK##*/}
codex_root=${CODEX_HOME:-$HOME/.codex}

# listed_entry SPEC: the `codex plugin list --json` entry of SPEC when it is
# installed and enabled, else nothing.
listed_entry() {
  local list
  list=$(codex plugin list --json) || die "codex plugin list --json failed"
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$list" ||
    die "codex plugin list --json printed no JSON object"
  jq -c --arg spec "$1" \
    'first((.installed // [])[] | select(.pluginId == $spec and .installed == true and .enabled == true)) // empty' \
    <<<"$list"
}

# lock_minimum PATH: the minimum version at the lock PATH.
lock_minimum() {
  local value minimum
  value=$(methods_lock_get "$1" "$component") || exit 1
  minimum=$(jq -r 'if type == "string" then .
    elif type == "object" then ([.minimum_version, .version] | map(strings | select(length > 0)) | first // empty)
    else empty end' <<<"$value")
  [[ -n $minimum ]] ||
    die "$1 in $lock_name is not a version (a string, or an entry with minimum_version or version)"
  printf '%s\n' "$minimum"
}

# ensure_plugin PLUGIN_JSON: installs (install mode) and verifies one entry.
ensure_plugin() {
  local plugin=$1 spec name market entry version source_kind source_path dir manifest
  local manifest_version minimum_at minimum skill
  spec=$(jq -r '.spec // empty | strings' <<<"$plugin")
  [[ $spec =~ ^([A-Za-z0-9._-]+)@([A-Za-z0-9._-]+)$ ]] ||
    die "codex plugin spec must look like NAME@MARKETPLACE: ${spec:-none}"
  name=${BASH_REMATCH[1]}
  market=${BASH_REMATCH[2]}

  entry=$(listed_entry "$spec")
  if [[ -z $entry ]]; then
    [[ $check_only != 1 ]] ||
      die "codex plugin $spec is not installed and enabled; run 'dotsteward agents install --profile $profile'"
    log "codex plugin $spec: installing with codex plugin add"
    codex plugin add "$spec" || die "codex plugin add $spec failed"
    entry=$(listed_entry "$spec")
    [[ -n $entry ]] || die "codex plugin $spec is still not installed and enabled after codex plugin add"
  fi

  # The version names a directory: a plain version string only.
  version=$(jq -r '.version // empty | strings' <<<"$entry")
  [[ $version =~ ^[A-Za-z0-9][A-Za-z0-9.+_~-]*$ ]] ||
    die "codex plugin $spec reports an invalid version: ${version:-none}"

  source_kind=$(jq -r '.source.source // empty | strings' <<<"$entry")
  source_path=$(jq -r '.source.path // empty | strings' <<<"$entry")
  if [[ $source_kind == local && $source_path == /* ]]; then
    dir=$source_path
  else
    dir=$codex_root/plugins/cache/$market/$name/$version
  fi
  manifest=$dir/.codex-plugin/plugin.json
  [[ -f $manifest ]] || die "codex plugin $spec $version has no plugin manifest at $manifest"
  manifest_version=$(jq -r '.version // empty | strings' "$manifest" 2>/dev/null) ||
    die "codex plugin $spec: $manifest is not valid JSON"
  [[ $manifest_version == "$version" ]] ||
    die "codex plugin $spec is listed as $version but $manifest says ${manifest_version:-no version}"

  minimum_at=$(jq -r '.minimumAt // empty | strings' <<<"$plugin")
  if [[ -n $minimum_at ]]; then
    minimum=$(lock_minimum "$minimum_at")
    methods_version_at_least "$version" "$minimum" ||
      die "codex plugin $spec $version is older than the minimum $minimum ($minimum_at in $lock_name)"
  fi

  while IFS= read -r skill; do
    [[ $skill =~ ^[A-Za-z0-9._-]+$ && $skill != . && $skill != .. ]] ||
      die "codex plugin $spec: invalid required skill directory: $skill"
    [[ -f $dir/skills/$skill/SKILL.md ]] ||
      die "codex plugin $spec $version lacks the skill $skill ($dir/skills/$skill/SKILL.md)"
  done < <(jq -r '(.requiredSkillDirectories // [])[] | strings' <<<"$plugin")

  log "codex plugin $spec $version verified"
}

# shellcheck disable=SC2016 # a jq program: $component is a jq variable
listed=$(config_query -c --arg component "$component" \
  '.components[$component].options.plugins // [] | if type == "array" then .[] else error("not a list") end')
plugins=()
if [[ -n $listed ]]; then
  mapfile -t plugins <<<"$listed"
fi
((${#plugins[@]})) || exit 0

require_command codex
for plugin in "${plugins[@]}"; do
  ensure_plugin "$plugin"
done
