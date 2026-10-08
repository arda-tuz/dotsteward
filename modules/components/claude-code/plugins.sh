#!/usr/bin/env bash
# The plugins hook of the claude-code catalog component (agentsPost). It runs
# with the hook environment of `dotsteward agents install|check` and reads
# the plugin list from [components.claude-code] options of the instance's
# workstation.toml:
#
#   [[components.claude-code.options.plugins]]   # one table per plugin
#   spec = "NAME@MARKETPLACE"
#   marketplace = "OWNER/REPO"                   # optional
#   minimumAt = "<versions.lock.json path>"      # optional
#   requiredFiles = ["<relative path>", ...]     # optional
#   trackAt = "<versions.lock.json path>"        # read by the pins engine
#   watched = ["<path pattern>", ...]            # read by the pins engine
#
# install (DOTSTEWARD_CHECK_ONLY=0) runs `claude plugin marketplace add
# OWNER/REPO` for a marketplace that `claude plugin marketplace list --json`
# does not list, `claude plugin install SPEC --scope user` for a plugin that
# `claude plugin list --json` does not list at user scope, and `claude plugin
# enable SPEC --scope user` for one listed there but disabled. It never
# confirms a command a marketplace declares: such a plugin is installed once
# by hand. Both modes then verify every plugin:
#   - a marketplace it names is listed with that name, from that GitHub
#     repository;
#   - it is listed at user scope and enabled, with an existing install
#     directory (installPath);
#   - with minimumAt, the listed version is a dotted version, the plugin
#     manifest .claude-plugin/plugin.json in that directory carries the same
#     version, and it is at least the lock value at minimumAt (a version
#     string, or an entry with minimum_version or version); a newer plugin
#     passes, an older one fails and is never upgraded silently;
#   - every required file exists in that directory.
# The first problem ends the hook with exit status 1.
set -Eeuo pipefail

[[ -n ${DOTSTEWARD_LIB:-} && -n ${DOTSTEWARD_INSTANCE:-} ]] || {
  printf '[dotsteward] ERROR: the claude-code plugins hook runs from dotsteward agents (DOTSTEWARD_LIB and DOTSTEWARD_INSTANCE are not set)\n' >&2
  exit 1
}

# shellcheck source=cli/lib/lib.sh
source "$DOTSTEWARD_LIB/lib.sh"
# shellcheck source=cli/lib/config.sh
source "$DOTSTEWARD_LIB/config.sh"
# shellcheck source=cli/lib/methods.sh
source "$DOTSTEWARD_LIB/methods.sh"

config_load "$DOTSTEWARD_INSTANCE"

component=${DOTSTEWARD_COMPONENT:-claude-code}
check_only=${DOTSTEWARD_CHECK_ONLY:-0}
profile=${DOTSTEWARD_PROFILE:-$DS_PROFILES_DEFAULT}
lock_name=${DS_PINS_VERSIONS_LOCK##*/}

# json_list WHAT ARG...: the JSON list that `claude ARG...` prints.
json_list() {
  local what=$1 list
  shift
  list=$(claude "$@") || die "claude $* failed"
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$list" || die "claude $* printed no JSON list of $what"
  printf '%s\n' "$list"
}

# listed_marketplace NAME: the `claude plugin marketplace list --json` entry
# named NAME, else nothing.
listed_marketplace() {
  json_list marketplaces plugin marketplace list --json |
    jq -c --arg name "$1" 'first(.[] | select(.name == $name)) // empty'
}

# listed_plugin SPEC [any]: the `claude plugin list --json` entry of SPEC at
# user scope when it is enabled (or in any state with "any"), else nothing.
listed_plugin() {
  json_list plugins plugin list --json |
    jq -c --arg spec "$1" --arg state "${2:-enabled}" \
      'first(.[] | select(.id == $spec and .scope == "user" and ($state == "any" or .enabled == true))) // empty'
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

# ensure_marketplace NAME REPO: adds (install mode) and verifies one
# GitHub marketplace.
ensure_marketplace() {
  local market=$1 repo=$2 entry
  entry=$(listed_marketplace "$market")
  if [[ -z $entry ]]; then
    [[ $check_only != 1 ]] ||
      die "claude marketplace $market ($repo) is not added; run 'dotsteward agents install --profile $profile'"
    log "claude marketplace $market: adding $repo with claude plugin marketplace add"
    claude plugin marketplace add "$repo" || die "claude plugin marketplace add $repo failed"
    entry=$(listed_marketplace "$market")
    [[ -n $entry ]] || die "claude plugin marketplace add $repo did not add the marketplace $market"
  fi
  jq -e --arg repo "$repo" '.source == "github" and .repo == $repo' >/dev/null <<<"$entry" ||
    die "claude marketplace $market is added from $(jq -r '"\(.source // "unknown") \(.repo // .url // .path // "")"' <<<"$entry"), not from github $repo"
}

# ensure_plugin PLUGIN_JSON: installs (install mode) and verifies one entry.
ensure_plugin() {
  local plugin=$1 spec market repo entry version dir manifest manifest_version minimum_at minimum file
  spec=$(jq -r '.spec // empty | strings' <<<"$plugin")
  [[ $spec =~ ^[A-Za-z0-9._-]+@([A-Za-z0-9._-]+)$ ]] ||
    die "claude plugin spec must look like NAME@MARKETPLACE: ${spec:-none}"
  market=${BASH_REMATCH[1]}

  repo=$(jq -r '.marketplace // empty | strings' <<<"$plugin")
  if [[ -n $repo ]]; then
    [[ $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
      die "claude plugin $spec: marketplace must be a GitHub repository OWNER/REPO: $repo"
    ensure_marketplace "$market" "$repo"
  fi

  entry=$(listed_plugin "$spec")
  if [[ -z $entry ]]; then
    [[ $check_only != 1 ]] ||
      die "claude plugin $spec is not installed and enabled at user scope; run 'dotsteward agents install --profile $profile'"
    if [[ -n $(listed_plugin "$spec" any) ]]; then
      log "claude plugin $spec: enabling with claude plugin enable"
      claude plugin enable "$spec" --scope user || die "claude plugin enable $spec --scope user failed"
      entry=$(listed_plugin "$spec")
      [[ -n $entry ]] ||
        die "claude plugin $spec is still not installed and enabled at user scope after claude plugin enable"
    else
      log "claude plugin $spec: installing with claude plugin install"
      claude plugin install "$spec" --scope user ||
        die "claude plugin install $spec --scope user failed; a plugin whose marketplace asks for a confirmation is installed once by hand"
      entry=$(listed_plugin "$spec")
      [[ -n $entry ]] ||
        die "claude plugin $spec is still not installed and enabled at user scope after claude plugin install"
    fi
  fi

  version=$(jq -r '.version // empty | strings' <<<"$entry")
  dir=$(jq -r '.installPath // empty | strings' <<<"$entry")
  [[ $dir == /* && -d $dir ]] || die "claude plugin $spec has no install directory: ${dir:-none}"

  minimum_at=$(jq -r '.minimumAt // empty | strings' <<<"$plugin")
  if [[ -n $minimum_at ]]; then
    # Marketplace plugins without a manifest version list a commit instead.
    [[ $version =~ ^[0-9]+([.][0-9]+)*$ ]] ||
      die "claude plugin $spec reports the version ${version:-none}, which minimumAt cannot compare (a dotted version is needed)"
    manifest=$dir/.claude-plugin/plugin.json
    [[ -f $manifest ]] || die "claude plugin $spec $version has no plugin manifest at $manifest"
    manifest_version=$(jq -r '.version // empty | strings' "$manifest" 2>/dev/null) ||
      die "claude plugin $spec: $manifest is not valid JSON"
    [[ $manifest_version == "$version" ]] ||
      die "claude plugin $spec is listed as $version but $manifest says ${manifest_version:-no version}"
    minimum=$(lock_minimum "$minimum_at")
    methods_version_at_least "$version" "$minimum" ||
      die "claude plugin $spec $version is older than the minimum $minimum ($minimum_at in $lock_name)"
  fi

  while IFS= read -r file; do
    [[ $file =~ ^[A-Za-z0-9._/+-]+$ && /$file/ != *//* && /$file/ != */./* && /$file/ != */../* ]] ||
      die "claude plugin $spec: invalid required file: $file"
    [[ -f $dir/$file ]] || die "claude plugin $spec ${version:-unversioned} lacks the file $file ($dir/$file)"
  done < <(jq -r '(.requiredFiles // [])[] | strings' <<<"$plugin")

  log "claude plugin $spec ${version:-unversioned} verified"
}

# shellcheck disable=SC2016 # a jq program: $component is a jq variable
listed=$(config_query -c --arg component "$component" \
  '.components[$component].options.plugins // [] | if type == "array" then .[] else error("not a list") end')
plugins=()
if [[ -n $listed ]]; then
  mapfile -t plugins <<<"$listed"
fi
((${#plugins[@]})) || exit 0

require_command claude
for plugin in "${plugins[@]}"; do
  ensure_plugin "$plugin"
done
