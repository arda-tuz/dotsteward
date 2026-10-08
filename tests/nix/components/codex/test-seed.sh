# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# shellcheck disable=SC2016 # Nix expressions and jq programs in single quotes
# The codex seed: schema version 1, no flake input, one
# release pin per platform under agent_tools.codex.<platform> whose URL is
# the official release asset the module installs on that platform, and every
# lock path the component reads is in it.
# shellcheck source=tests/nix/components/codex/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/codex/helpers.sh"

[[ -f $codex_seed ]] || ds_fail "missing $codex_seed"
assert_json "$codex_seed" '.schema_version == 1 and .component == "codex" and .flake_inputs == {}'
assert_json "$codex_seed" '.versions_lock | keys == ["agent_tools"]'
assert_json "$codex_seed" '.versions_lock.agent_tools | keys == ["codex"]'
assert_json "$codex_seed" '.versions_lock.agent_tools.codex | keys == ["darwin", "linux"]'

# The seed validates against schema/seed.schema.json (the framework seed
# check of dotsteward static).
cd "$DS_REPO_ROOT"
assert_exit 0 ./cli/dotsteward static --sandbox --only seeds
assert_contains "$DS_STDOUT" "static checks passed (framework): seeds"

# Each pin: the same version, an https URL of the official release of that
# version and of the platform's asset, a positive size, a hex SHA-256.
both=$(codex_instance both '["x86_64-linux", "aarch64-darwin"]')
assets=$(inst_json "let inst = $(codex_expr "$both");
  install = system: (homeOf inst system \"workstation\").dotsteward.components.codex.install.official-binary;
in { linux = (install \"x86_64-linux\").asset.linux; darwin = (install \"aarch64-darwin\").asset.darwin; }")
version=$(jq -r '.versions_lock.agent_tools.codex.linux.version' "$codex_seed")
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || ds_fail "invalid seed version: $version"
for platform in linux darwin; do
  pin=$(jq -c --arg p "$platform" '.versions_lock.agent_tools.codex[$p]' "$codex_seed")
  asset=$(jq -r --arg p "$platform" '.[$p]' <<<"$assets")
  json_check "$pin" 'keys' '["sha256","size","url","version"]'
  json_check "$pin" '.version' "\"$version\""
  json_check "$pin" '.url' "\"https://github.com/openai/codex/releases/download/rust-v$version/$asset\""
  json_check "$pin" '(.size | type == "number" and . > 0 and . == floor)' 'true'
  json_check "$pin" '.sha256 | test("^[0-9a-f]{64}$")' 'true'
done
assert_json "$codex_seed" '.versions_lock.agent_tools.codex.linux.sha256 != .versions_lock.agent_tools.codex.darwin.sha256'

# Every lock path the component reads (install pins of both methods on both
# systems, pin rules) is in the seed: the codex rows of the framework's seed
# lock-path check.
problems=$(inst_json "import (repoRoot + \"/tests/static/seed-lock-paths.nix\") {
  nixpkgs = \"$DS_NIXPKGS\"; homeManager = \"$DS_HOME_MANAGER\"; repo = \"$DS_REPO_ROOT\";
}")
assert_eq '[]' "$(jq -c '[.[] | select(startswith("codex/"))]' <<<"$problems")" "codex seed lock paths"

# The instance lock dotsteward init writes from the seed is what the
# component reads: the install pin of each system resolves to its entry.
for platform in linux darwin; do
  assert_json "$both/versions.lock.json" ".agent_tools.codex.$platform == $(jq -c ".versions_lock.agent_tools.codex.$platform" "$codex_seed")"
done
