#!/usr/bin/env bash
# The plugins hook of the codex catalog component (agentsPost). It runs with the
# hook environment of `dotsteward agents install|check` and reads the plugin
# list from [components.codex] options of the instance's workstation.toml:
#
#   [[components.codex.options.plugins]]          # one table per plugin
#   spec = "NAME@MARKETPLACE"
#   marketplace = "OWNER/REPO"                   # optional
#   minimumAt = "<versions.lock.json path>"       # optional
#   requiredSkillDirectories = ["<dir>", ...]     # optional
#   machines = ["<machine name>", ...]           # optional: only on these machines
#
# install (DOTSTEWARD_CHECK_ONLY=0) runs `codex plugin marketplace add
# OWNER/REPO` for an entry's marketplace that `codex plugin marketplace list
# --json` does not list under the spec's marketplace name, then `codex plugin
# add SPEC` for a plugin that `codex plugin list --json` does not show
# installed and enabled. Each list is read once per run for every entry and
# again only after a command that changes it (marketplace add, plugin add).
# Codex refreshes configured Git marketplaces and their plugins itself. Both
# modes then verify every plugin:
#   - the marketplace an entry names is listed under the spec's marketplace
#     name, from https://github.com/OWNER/REPO (a trailing .git and letter
#     case aside);
#   - it is listed installed and enabled, with a plain version string;
#   - its directory (the cached copy
#     ${CODEX_HOME:-~/.codex}/plugins/cache/<marketplace>/<name>/<version>
#     when it holds a manifest, else the listed local source path) holds
#     .codex-plugin/plugin.json with the listed version: the listed version
#     is that of the cached copy, which Codex loads, while the local source
#     of a plugin at the root of a Git marketplace is the marketplace
#     snapshot, which a session that ends early leaves ahead of the cache;
#   - the version is at least the lock value at minimumAt (a version string,
#     or an entry with minimum_version or version); a newer plugin passes,
#     an older one fails and is never upgraded silently;
#   - skills/<dir>/SKILL.md exists for every required skill directory.
# The first problem ends the hook with exit status 1. Codex lists the plugins
# of a remote marketplace from a remote catalog request, and when that
# request fails (the network is down for a moment) it only warns and lists
# them as missing; so check mode reads the plugin list again for a plugin it
# does not show, after each pause of relist_pauses, before it fails.
# install mode adds a missing plugin as before.
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
# The pauses (seconds) before check mode reads the plugin list again for a
# plugin it does not show: about half a minute in all.
relist_pauses=(2 4 8 16)

# json_object ARG...: the JSON object that `codex ARG...` prints.
json_object() {
  local list
  list=$(codex "$@") || die "codex $* failed"
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$list" || die "codex $* printed no JSON object"
  printf '%s\n' "$list"
}

# The two lists of the codex CLI, read once for every entry: empty until the
# first read, and emptied by the commands that change them, so the next
# lookup reads the list as it is after the change.
plugins_listed=''
marketplaces=''

# load_plugins, load_marketplaces: read a list unless it is current. They
# run in the hook's own shell, never in a command substitution, so the list
# they read stays for the next lookup.
load_plugins() {
  [[ -n $plugins_listed ]] || plugins_listed=$(json_object plugin list --json)
}

load_marketplaces() {
  [[ -n $marketplaces ]] || marketplaces=$(json_object plugin marketplace list --json)
}

# listed_entry SPEC: the plugin list entry of SPEC when it is installed and
# enabled, else nothing (after load_plugins).
listed_entry() {
  jq -c --arg spec "$1" \
    'first((.installed // [])[] | select(.pluginId == $spec and .installed == true and .enabled == true)) // empty' \
    <<<"$plugins_listed"
}

# listed_marketplace NAME: the marketplace list entry named NAME, else
# nothing (after load_marketplaces).
listed_marketplace() {
  jq -c --arg name "$1" 'first((.marketplaces // [])[] | select(.name == $name)) // empty' <<<"$marketplaces"
}

# ensure_marketplace NAME REPO: adds (install mode) and verifies one GitHub
# marketplace.
ensure_marketplace() {
  local market=$1 repo=$2 entry source normalized
  load_marketplaces
  entry=$(listed_marketplace "$market")
  if [[ -z $entry ]]; then
    [[ $check_only != 1 ]] ||
      die "codex marketplace $market ($repo) is not added; run 'dotsteward agents install --profile $profile'"
    log "codex marketplace $market: adding $repo with codex plugin marketplace add"
    marketplaces=''
    codex plugin marketplace add "$repo" || die "codex plugin marketplace add $repo failed"
    load_marketplaces
    entry=$(listed_marketplace "$market")
    [[ -n $entry ]] || die "codex plugin marketplace add $repo did not add the marketplace $market"
  fi
  source=$(jq -r '.marketplaceSource.source // empty | strings' <<<"$entry")
  normalized=${source%/}
  normalized=${normalized%.git}
  [[ $(jq -r '.marketplaceSource.sourceType // empty | strings' <<<"$entry") == git &&
    ${normalized,,} == "https://github.com/${repo,,}" ]] ||
    die "codex marketplace $market is added from ${source:-an unknown source}, not from github $repo"
  log "codex marketplace $market ($repo) verified"
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
  local plugin=$1 spec name market repo entry version source_kind source_path dir manifest
  local manifest_version minimum_at minimum skill pause
  spec=$(jq -r '.spec // empty | strings' <<<"$plugin")
  [[ $spec =~ ^([A-Za-z0-9._-]+)@([A-Za-z0-9._-]+)$ ]] ||
    die "codex plugin spec must look like NAME@MARKETPLACE: ${spec:-none}"
  name=${BASH_REMATCH[1]}
  market=${BASH_REMATCH[2]}

  repo=$(jq -r '.marketplace // empty | strings' <<<"$plugin")
  [[ -z $repo ]] || ensure_marketplace "$market" "$repo"

  load_plugins
  entry=$(listed_entry "$spec")
  if [[ -z $entry && $check_only == 1 ]]; then
    for pause in "${relist_pauses[@]}"; do
      warn "codex plugin $spec is not listed; reading the plugin list again in ${pause}s (a failed remote catalog request lists plugins as missing)"
      sleep "$pause"
      plugins_listed=''
      load_plugins
      entry=$(listed_entry "$spec")
      [[ -z $entry ]] || break
    done
  fi
  if [[ -z $entry ]]; then
    [[ $check_only != 1 ]] ||
      die "codex plugin $spec is not installed and enabled; run 'dotsteward agents install --profile $profile'"
    log "codex plugin $spec: installing with codex plugin add"
    plugins_listed=''
    codex plugin add "$spec" || die "codex plugin add $spec failed"
    load_plugins
    entry=$(listed_entry "$spec")
    [[ -n $entry ]] || die "codex plugin $spec is still not installed and enabled after codex plugin add"
  fi

  # The version names a directory: a plain version string only.
  version=$(jq -r '.version // empty | strings' <<<"$entry")
  [[ $version =~ ^[A-Za-z0-9][A-Za-z0-9.+_~-]*$ ]] ||
    die "codex plugin $spec reports an invalid version: ${version:-none}"

  source_kind=$(jq -r '.source.source // empty | strings' <<<"$entry")
  source_path=$(jq -r '.source.path // empty | strings' <<<"$entry")
  dir=$codex_root/plugins/cache/$market/$name/$version
  if [[ ! -f $dir/.codex-plugin/plugin.json && $source_kind == local && $source_path == /* ]]; then
    dir=$source_path
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

# The entries this machine does not leave out (a plugin for other machines, or one
# hosts/<name>.toml declines).
# shellcheck disable=SC2016 # a jq program: $component and $skip are jq variables
listed=$(config_query -c --arg component "$component" --argjson skip "${DS_SKIP_PLUGINS_JSON:-[]}" \
  '.components[$component].options.plugins // [] | if type == "array" then .[] else error("not a list") end
    | select((.spec? // "") as $spec | $skip | index($spec) | not)')
plugins=()
if [[ -n $listed ]]; then
  mapfile -t plugins <<<"$listed"
fi
((${#plugins[@]})) || exit 0

require_command codex
for plugin in "${plugins[@]}"; do
  ensure_plugin "$plugin"
done
