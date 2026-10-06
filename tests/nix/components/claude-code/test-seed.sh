# shellcheck shell=bash
# shellcheck disable=SC2016 # jq programs and Nix expressions in single quotes
# The claude-code seed (SPEC 5.6): it validates against
# schema/seed.schema.json, holds every lock path the component reads with
# any of its methods (the release pin of each platform and the DEB pin), and
# its values are well-formed official download pins: HTTPS URLs of the
# vendor's release and APT hosts that carry the pinned version, positive
# sizes and SHA-256 digests. Merged into an instance lock the way
# `dotsteward init` merges it, it satisfies the pins the component declares.
# shellcheck source=tests/nix/components/claude-code/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/claude-code/helpers.sh"

[[ -f $cc_seed ]] || ds_fail "missing $cc_seed"
assert_json "$cc_seed" '.schema_version == 1 and .component == "claude-code" and .flake_inputs == {}'

# A framework copy whose catalog is claude-code alone, so other components'
# seeds do not decide this test.
fw=$DS_TEST_ROOT/fw
mkdir -p "$fw"
for entry in VERSION cli schema privacy lib nix modules tests; do
  cp -R "$DS_REPO_ROOT/$entry" "$fw/"
done
chmod -R u+w "$fw"
rm -rf "$fw/modules/components"
mkdir -p "$fw/modules/components"
cp -R "$cc_component_dir" "$fw/modules/components/"

# Schema validation with the framework's own validator (the seeds check of
# `dotsteward static`).
assert_exit 0 bash -c 'cd "$1" && ./cli/dotsteward static --sandbox --only seeds' _ "$fw"
assert_contains "$DS_STDOUT" "static checks passed (framework): seeds"

# Shape of the pins.
assert_json "$cc_seed" '.versions_lock | keys == ["agent_tools", "desktop_packages"]'
assert_json "$cc_seed" '.versions_lock.agent_tools["claude-code"] | keys == ["darwin-arm64", "linux-x64"]'
for release in linux-x64 darwin-arm64; do
  assert_json "$cc_seed" "\"$release\" as \$r"' |
    .versions_lock.agent_tools["claude-code"][$r] as $p
    | ($p | keys == ["sha256", "size", "url", "version"])
    and ($p.version | test("^[0-9]+[.][0-9]+[.][0-9]+$"))
    and $p.url == ("https://downloads.claude.ai/claude-code-releases/" + $p.version + "/" + $r + "/claude")
    and ($p.size | type == "number" and . > 0 and . == floor)
    and ($p.sha256 | test("^[0-9a-f]{64}$"))'
done
# Both platforms pin the same release.
assert_json "$cc_seed" '.versions_lock.agent_tools["claude-code"] | [.[].version] | unique | length == 1'
assert_json "$cc_seed" '.versions_lock.agent_tools["claude-code"] | [.[].sha256] | unique | length == 2'
assert_json "$cc_seed" '
  .versions_lock.desktop_packages["claude-code"] as $p
  | ($p | keys == ["minimum_version", "sha256", "size", "url"])
  and ($p.minimum_version | test("^[0-9]+[.][0-9]+[.][0-9]+-[0-9]+$"))
  and $p.url == ("https://downloads.claude.ai/claude-code/apt/stable/pool/main/c/claude-code/claude-code_" + $p.minimum_version + "_amd64.deb")
  and ($p.size | type == "number" and . > 0 and . == floor)
  and ($p.sha256 | test("^[0-9a-f]{64}$"))'

# Every lock path the component reads exists in the seed: the lock-path
# half of the static seeds test (tests/static/seed-lock-paths.nix), on the
# claude-code-only copy.
[[ -n ${DS_HOME_MANAGER:-} && -n ${nix_lib_store:-} ]] || nix_core_init
env -u NIX_REMOTE -u NIX_PATH \
  NIX_STORE_DIR="$nix_lib_store/store" \
  NIX_STATE_DIR="$nix_lib_store/state" \
  NIX_LOG_DIR="$nix_lib_store/log" \
  NIX_CONF_DIR="$nix_lib_store/etc" \
  NIX_LOCALSTATE_DIR="$nix_lib_store/state" \
  nix-instantiate --eval --strict --json \
  --argstr nixpkgs "$DS_NIXPKGS" --argstr homeManager "$DS_HOME_MANAGER" --argstr repo "$fw" \
  "$fw/tests/static/seed-lock-paths.nix" >"$DS_TEST_ROOT/lock-paths.json" 2>"$DS_TEST_ROOT/lock-paths.err" ||
  ds_fail "lock-path evaluation failed: $(<"$DS_TEST_ROOT/lock-paths.err")"
assert_eq '[]' "$(jq -c . "$DS_TEST_ROOT/lock-paths.json")" "lock paths read by claude-code"

# The seed merged into the fixture lock (deep merge, as init does) holds the
# `at` path of every download-pin rule and latest declaration, for every
# method on every system.
merged=$DS_TEST_ROOT/versions.lock.json
jq -s '.[0] * .[1].versions_lock' "$cc_fixture_root/versions.lock.json" "$cc_seed" >"$merged"
paths=$(cc_json 'lib.unique (lib.concatMap (i: lib.concatMap (system:
    let m = ccManifest i system; own = lib.filter (e: e.component == "claude-code"); in
    map (e: e.at) (own m.pins.rules ++ own m.pins.latest)) (builtins.attrNames i.dotstewardManifest))
  [ (cc { }) (cc { config = ccCase "method-deb"; }) (cc { config = ccCase "method-by-platform"; }) ])')
assert_eq '["agent_tools.claude-code.darwin-arm64","agent_tools.claude-code.linux-x64","desktop_packages.claude-code"]' \
  "$(jq -c 'sort' <<<"$paths")" "pinned lock paths"
while IFS= read -r path; do
  assert_json "$merged" "\"$path\" as \$path"' | getpath($path | split(".")) | type == "object"'
done < <(jq -r '.[]' <<<"$paths")

# The release pins of the seed follow the url_contains template of their
# rule.
while IFS=$'\t' read -r at template; do
  url=$(jq -r --arg at "$at" 'getpath($at | split(".")).url' "$merged")
  version=$(jq -r --arg at "$at" 'getpath($at | split(".")) | .version // .minimum_version' "$merged")
  needle=${template//\{.version\}/$version}
  needle=${needle//\{.minimum_version\}/$version}
  assert_contains "$url" "$needle" "url of $at"
done < <(cc_json 'lib.concatMap (i: lib.concatMap (system:
    map (r: { inherit (r) at url_contains; }) (lib.filter (e: e.component == "claude-code") (ccManifest i system).pins.rules))
    (builtins.attrNames i.dotstewardManifest))
  [ (cc { }) (cc { config = ccCase "method-deb"; }) ]' | jq -r '.[] | [.at, .url_contains] | @tsv')
