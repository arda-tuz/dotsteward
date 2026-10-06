# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# shellcheck disable=SC2016,SC2088 # jq programs and literal ~/ paths in single quotes
# The opencode-pi seed and documents (SPEC 3.5, 5.6, 14): schema version 1,
# no flake input; the Pi source pins (tag, revision, SRI hashes, model data
# URL of the same version) and nix_packages.pi; one OpenCode release pin per
# platform at the same version whose URL is the official release asset the
# module installs there; every lock path the component reads is in the seed;
# the README records the verification status, maintenance.md exists.
# shellcheck source=tests/nix/components/opencode-pi/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/opencode-pi/helpers.sh"

[[ -f $op_seed ]] || ds_fail "missing $op_seed"
assert_json "$op_seed" '.schema_version == 1 and .component == "opencode-pi" and .flake_inputs == {}'
assert_json "$op_seed" '.versions_lock | keys == ["agent_tools", "nix_packages"]'
assert_json "$op_seed" '.versions_lock.agent_tools | keys == ["opencode", "opencode-darwin", "pi"]'
assert_json "$op_seed" '.versions_lock.nix_packages | keys == ["pi"]'

# The seed validates against schema/seed.schema.json (the framework seed
# check of dotsteward static).
cd "$DS_REPO_ROOT"
assert_exit 0 ./cli/dotsteward static --sandbox --only seeds
assert_contains "$DS_STDOUT" "static checks passed (framework): seeds"

# --- Pi ------------------------------------------------------------------------------

pi=$(jq -c '.versions_lock.agent_tools.pi' "$op_seed")
version=$(jq -r '.version' <<<"$pi")
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || ds_fail "invalid Pi version: $version"
json_check "$pi" '.package' '"@earendil-works/pi-coding-agent"'
json_check "$pi" '.source' '"https://github.com/earendil-works/pi"'
json_check "$pi" '.official_tag' "\"v$version\""
json_check "$pi" '.tag_revision | test("^[0-9a-f]{40}$")' 'true'
json_check "$pi" '.model_data_url' "\"https://registry.npmjs.org/@earendil-works/pi-ai/-/pi-ai-$version.tgz\""
for key in source_nix_sha256 npm_dependencies_nix_sha256 model_data_nix_sha256; do
  json_check "$pi" ".$key | test(\"^sha256-[A-Za-z0-9+/]{43}=\$\")" 'true'
done
assert_json "$op_seed" ".versions_lock.nix_packages.pi == { expected: \"$version\", resolved: \"$version\" }"

# --- OpenCode ---------------------------------------------------------------------------

linux=$(jq -c '.versions_lock.agent_tools.opencode' "$op_seed")
darwin=$(jq -c '.versions_lock.agent_tools."opencode-darwin"' "$op_seed")
opencode_version=$(jq -r '.minimum_version' <<<"$linux")
[[ $opencode_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || ds_fail "invalid OpenCode version: $opencode_version"
json_check "$linux" 'keys' '["minimum_version","native_auto_updates","sha256","size","source_revision","url"]'
json_check "$darwin" 'keys' '["minimum_version","sha256","size","source_revision","url"]'
json_check "$darwin" '.minimum_version' "\"$opencode_version\""
assets=$(op_json '{
  linux = (component { }).install.official-binary.asset.linux;
  darwin = (component { system = "aarch64-darwin"; }).install.official-binary.asset.darwin;
}')
for platform in linux darwin; do
  pin=${!platform}
  asset=$(jq -r --arg p "$platform" '.[$p]' <<<"$assets")
  json_check "$pin" '.url' "\"https://github.com/anomalyco/opencode/releases/download/v$opencode_version/$asset\""
  json_check "$pin" '(.size | type == "number" and . > 0 and . == floor)' 'true'
  json_check "$pin" '.sha256 | test("^[0-9a-f]{64}$")' 'true'
  json_check "$pin" '.source_revision | test("^[0-9a-f]{40}$")' 'true'
done
assert_eq "$(jq -r .source_revision <<<"$linux")" "$(jq -r .source_revision <<<"$darwin")" "one release revision"
[[ $(jq -r .sha256 <<<"$linux") != "$(jq -r .sha256 <<<"$darwin")" ]] || ds_fail "the release pins share a digest"
json_check "$linux" '.native_auto_updates' 'true'

# --- Lock paths ---------------------------------------------------------------------------

# Every lock path the component reads (install pins of both methods on both
# systems, probes, pin rules) is in the seed: the opencode-pi rows of the
# framework's seed lock-path check.
problems=$(core_json "import (repoRoot + \"/tests/static/seed-lock-paths.nix\") {
  nixpkgs = \"$DS_NIXPKGS\"; homeManager = \"$DS_HOME_MANAGER\"; repo = \"$DS_REPO_ROOT\";
}")
assert_eq '[]' "$(jq -c '[.[] | select(startswith("opencode-pi/"))]' <<<"$problems")" "opencode-pi seed lock paths"

# The Pi package evaluates from the seed lock alone.
assert_op_eq "\"$version\"" '(piFor "x86_64-linux").version' "Pi version from the seed"

# --- Documents ------------------------------------------------------------------------------

readme=$op_dir/README.md
[[ -f $readme && -f $op_dir/maintenance.md ]] || ds_fail "README.md and maintenance.md are required"
# The verification record of SPEC 14: the OpenCode configuration path on
# both platforms and the Pi darwin build, each verified or not verified.
grep -qE 'OpenCode configuration path.*(verified on [0-9]{4}-[0-9]{2}-[0-9]{2} from|not verified)' "$readme" ||
  ds_fail "README.md lacks the verification record of the OpenCode configuration path"
grep -qE 'Pi on darwin.*(verified on [0-9]{4}-[0-9]{2}-[0-9]{2} from|not verified)' "$readme" ||
  ds_fail "README.md lacks the verification record of the Pi darwin build"
for needle in '~/.config/opencode/opencode.json' '~/.local/bin/opencode' '~/.pi/agent/AGENTS.md' \
  agent_tools.opencode agent_tools.opencode-darwin agent_tools.pi; do
  grep -qF -- "$needle" "$readme" || ds_fail "README.md does not mention $needle"
done

# --- The pins engine -------------------------------------------------------------------------

# An instance written from the seed (both systems, official-binary on both)
# passes `dotsteward pins check` with the component's pin rules once
# `pins sync` has filled the skills lock mirrors (whose parent objects must
# exist: sync never creates entries).
inst=$(op_instance pins)
sed -i -e 's/^systems = .*/systems = ["x86_64-linux", "aarch64-darwin"]/' -e '/^method = "external"$/d' \
  "$inst/workstation.toml"
jq --indent 2 '.nix_tools = {} | .release_tools = { opencode: {} }' "$inst/agent/skills.lock.json" >"$inst/skills.tmp"
mv -- "$inst/skills.tmp" "$inst/agent/skills.lock.json"
# flake.nix and flake.lock agreeing with the lock's flake_inputs.
jq -r '.flake_inputs[].reference | "# \"\(.)\""' "$inst/versions.lock.json" >"$inst/flake.nix"
jq --indent 2 '.flake_inputs as $inputs | {
  nodes: ({ root: { inputs: ($inputs | with_entries(.value = .key)) } }
    + ($inputs | with_entries(.value |= ((.reference | capture("^github:(?<owner>[^/]+)/(?<repo>[^/]+)/(?<rev>.+)$")) as $r
      | { locked: { type: "github", owner: $r.owner, repo: $r.repo, rev: .revision },
          original: { type: "github", owner: $r.owner, repo: $r.repo, rev: $r.rev } })))),
  root: "root",
  version: 7
}' "$inst/versions.lock.json" >"$inst/flake.lock"
write_mirrors "instance { root = /. + \"$inst\"; }" "$inst"

assert_exit 1 op_cli "$inst" pins check
assert_contains "$DS_STDERR" "skills:release_tools.opencode.version: expected '$opencode_version', found None"
assert_contains "$DS_STDERR" "skills:nix_tools.pi: expected '$version', found None"
assert_exit 0 op_cli "$inst" pins sync
assert_json "$inst/agent/skills.lock.json" ".nix_tools.pi == \"$version\""
assert_json "$inst/agent/skills.lock.json" \
  ".release_tools.opencode == ($linux | { version: .minimum_version, source_revision, url, size, sha256, native_auto_updates })"
assert_exit 0 op_cli "$inst" pins check

# A darwin pin that lags behind the Linux one, or names another asset, is
# reported.
lock_set() {
  jq --indent 2 --arg path "$1" --argjson value "$2" 'setpath($path | split("."); $value)' \
    "$inst/versions.lock.json" >"$inst/lock.tmp"
  mv -- "$inst/lock.tmp" "$inst/versions.lock.json"
}
lock_set agent_tools.opencode-darwin.minimum_version '"0.0.1"'
assert_exit 1 op_cli "$inst" pins check
assert_contains "$DS_STDERR" "agent_tools.opencode-darwin.minimum_version: expected '$opencode_version', found '0.0.1'"
lock_set agent_tools.opencode-darwin.minimum_version "\"$opencode_version\""
lock_set agent_tools.opencode-darwin.url "$(jq '.url | sub("darwin-arm64.zip$"; "darwin-x64.zip")' <<<"$darwin")"
assert_exit 1 op_cli "$inst" pins check
assert_contains "$DS_STDERR" "agent_tools.opencode-darwin.url"
