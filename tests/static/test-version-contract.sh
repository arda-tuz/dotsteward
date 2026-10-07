# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The VERSION contract (SPEC D19, 11.8): the single VERSION file feeds
# `dotsteward version`, the two plugin manifests and the two marketplace
# files. Every manifest exists and parses, every `version` key in it equals
# VERSION, each plugin manifest carries one, the Claude marketplace entry
# carries one, every marketplace entry names the dotsteward plugin and its
# local source resolves to the plugin directory holding that channel's
# manifest, and the Codex manifest's skills path exists.
# shellcheck source=tests/static/helpers.sh
source "$DS_REPO_ROOT/tests/static/helpers.sh"

CLAUDE_MARKETPLACE=.claude-plugin/marketplace.json
CODEX_MARKETPLACE=.agents/plugins/marketplace.json
CLAUDE_PLUGIN=plugins/dotsteward/.claude-plugin/plugin.json
CODEX_PLUGIN=plugins/dotsteward/.codex-plugin/plugin.json

# version_findings ROOT: one "path: problem" line per contract violation in
# the framework tree ROOT; empty when the contract holds.
version_findings() {
  local root=$1 version file value source
  if [[ ! -f $root/VERSION ]]; then
    printf 'VERSION: missing\n'
    return 0
  fi
  version=$(<"$root/VERSION")
  if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'VERSION: [%s] is not one X.Y.Z line\n' "$version"
    return 0
  fi

  value=$(cd "$root" && ./cli/dotsteward version --json | jq -r '.version')
  [[ $value == "$version" ]] || printf 'dotsteward version: [%s] differs from VERSION [%s]\n' "$value" "$version"

  for file in "$CLAUDE_MARKETPLACE" "$CODEX_MARKETPLACE" "$CLAUDE_PLUGIN" "$CODEX_PLUGIN"; do
    if [[ ! -f $root/$file ]]; then
      printf '%s: missing\n' "$file"
      continue
    fi
    if ! jq -e 'type == "object"' "$root/$file" >/dev/null 2>&1; then
      printf '%s: not a JSON object\n' "$file"
      continue
    fi
    while IFS= read -r value; do
      [[ $value == "$version" ]] || printf '%s: version [%s] differs from VERSION [%s]\n' "$file" "$value" "$version"
    done < <(jq -r '.. | objects | select(has("version")) | .version | tostring' "$root/$file")
    if [[ $file == */plugin.json ]]; then
      jq -e '.name == "dotsteward" and (.version | type == "string")' "$root/$file" >/dev/null ||
        printf '%s: name must be "dotsteward" and version a string\n' "$file"
    else
      jq -e '.name == "dotsteward" and (.plugins | type == "array" and length == 1)
          and .plugins[0].name == "dotsteward"' "$root/$file" >/dev/null ||
        printf '%s: must list exactly the dotsteward plugin\n' "$file"
    fi
  done

  # The Claude marketplace entry carries the version and a relative string
  # source holding the Claude manifest.
  if jq -e . "$root/$CLAUDE_MARKETPLACE" >/dev/null 2>&1; then
    jq -e '.plugins[0].version | type == "string"' "$root/$CLAUDE_MARKETPLACE" >/dev/null ||
      printf '%s: plugin entry lacks a version\n' "$CLAUDE_MARKETPLACE"
    source=$(jq -r '.plugins[0].source | strings' "$root/$CLAUDE_MARKETPLACE")
    if [[ $source != ./* || ! -f $root/$source/.claude-plugin/plugin.json ]]; then
      printf '%s: source [%s] does not hold .claude-plugin/plugin.json\n' "$CLAUDE_MARKETPLACE" "$source"
    fi
  fi

  # The Codex marketplace entry is a local source whose path (relative to the
  # marketplace root, the repository root) holds the Codex manifest.
  if jq -e . "$root/$CODEX_MARKETPLACE" >/dev/null 2>&1; then
    source=$(jq -r '.plugins[0].source | objects | select(.source == "local") | .path | strings' \
      "$root/$CODEX_MARKETPLACE")
    if [[ $source != ./* || ! -f $root/$source/.codex-plugin/plugin.json ]]; then
      printf '%s: local source path [%s] does not hold .codex-plugin/plugin.json\n' "$CODEX_MARKETPLACE" "$source"
    fi
  fi
  if jq -e . "$root/$CODEX_PLUGIN" >/dev/null 2>&1; then
    source=$(jq -r '.skills | strings' "$root/$CODEX_PLUGIN")
    if [[ $source != ./* || ! -d $root/plugins/dotsteward/$source ]]; then
      printf '%s: skills path [%s] is not a directory of the plugin\n' "$CODEX_PLUGIN" "$source"
    fi
  fi
}

# The real tree holds the contract.
assert_eq "" "$(version_findings "$DS_REPO_ROOT")" "version contract of the framework tree"
assert_json "$DS_REPO_ROOT/$CLAUDE_MARKETPLACE" '.plugins[0].source == "./plugins/dotsteward"'

# Drift in any file, a bumped VERSION alone, a missing manifest and a broken
# source path are each found.
fw=$DS_TEST_ROOT/fw
framework_copy "$fw"
for file in "$CLAUDE_MARKETPLACE" "$CLAUDE_PLUGIN" "$CODEX_PLUGIN"; do
  cp -- "$fw/$file" "$fw/$file.orig"
  jq '(.. | objects | select(has("version")) | .version) = "9.9.9"' "$fw/$file.orig" >"$fw/$file"
  assert_contains "$(version_findings "$fw")" "$file: version [9.9.9] differs from VERSION"
  mv -- "$fw/$file.orig" "$fw/$file"
done
# A version key added to the Codex marketplace must match as well.
cp -- "$fw/$CODEX_MARKETPLACE" "$fw/$CODEX_MARKETPLACE.orig"
jq '.plugins[0].version = "9.9.9"' "$fw/$CODEX_MARKETPLACE.orig" >"$fw/$CODEX_MARKETPLACE"
assert_contains "$(version_findings "$fw")" "$CODEX_MARKETPLACE: version [9.9.9] differs from VERSION"
mv -- "$fw/$CODEX_MARKETPLACE.orig" "$fw/$CODEX_MARKETPLACE"
assert_eq "" "$(version_findings "$fw")" "restored copy"

printf '9.9.9\n' >"$fw/VERSION"
findings=$(version_findings "$fw")
for file in "$CLAUDE_MARKETPLACE" "$CLAUDE_PLUGIN" "$CODEX_PLUGIN"; do
  assert_contains "$findings" "$file: version [$(<"$DS_REPO_ROOT/VERSION")] differs from VERSION [9.9.9]"
done
assert_not_contains "$findings" "dotsteward version:"
cp -- "$DS_REPO_ROOT/VERSION" "$fw/VERSION"

rm -- "$fw/$CODEX_PLUGIN"
findings=$(version_findings "$fw")
assert_contains "$findings" "$CODEX_PLUGIN: missing"
assert_contains "$findings" "$CODEX_MARKETPLACE: local source path [./plugins/dotsteward] does not hold"
cp -- "$DS_REPO_ROOT/$CODEX_PLUGIN" "$fw/$CODEX_PLUGIN"

jq '.plugins[0].source = "./plugins/elsewhere"' "$DS_REPO_ROOT/$CLAUDE_MARKETPLACE" >"$fw/$CLAUDE_MARKETPLACE"
assert_contains "$(version_findings "$fw")" "$CLAUDE_MARKETPLACE: source [./plugins/elsewhere] does not hold"
