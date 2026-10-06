# shellcheck shell=bash
# shellcheck disable=SC2016,SC2154,SC2164 # Nix expressions in single quotes; DS_* and vscode_* variables come from the harness and helpers.sh; errexit stops a failed cd
# The vscode seed (SPEC 5.6): schema version 1, valid against
# schema/seed.schema.json, no flake input, and the two pins of one VS Code
# release: desktop_packages.vscode (the Linux DEB) and
# desktop_packages.vscode-darwin-arm64 (the darwin archive), each a
# version-addressed URL of the official update service with its size and
# SHA-256. Every lock path the component reads is provided by the seed, and
# the pins engine accepts the component's rules over a lock started from it
# (and rejects a pin whose URL does not carry its version).
# shellcheck source=tests/nix/components/vscode/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/vscode/helpers.sh"

seed=$vscode_component/seed.json
[[ -f $seed ]] || ds_fail "missing modules/components/vscode/seed.json"

assert_json "$seed" '.schema_version == 1 and .component == "vscode"'
assert_json "$seed" '.flake_inputs == {}'
assert_json "$seed" '.versions_lock | keys == ["desktop_packages"]'
assert_json "$seed" '.versions_lock.desktop_packages | keys == ["vscode", "vscode-darwin-arm64"]'

# Both pins: one release, the official version-addressed download, a size
# and a digest.
assert_json "$seed" '.versions_lock.desktop_packages | [.[] | keys] == [["minimum_version", "sha256", "size", "url"], ["minimum_version", "sha256", "size", "url"]]'
assert_json "$seed" '.versions_lock.desktop_packages | .vscode.minimum_version == .["vscode-darwin-arm64"].minimum_version'
assert_json "$seed" '.versions_lock.desktop_packages.vscode | .minimum_version | test("^[0-9]+[.][0-9]+[.][0-9]+$")'
assert_json "$seed" '.versions_lock.desktop_packages.vscode
  | .url == ("https://update.code.visualstudio.com/" + .minimum_version + "/linux-deb-x64/stable")'
assert_json "$seed" '.versions_lock.desktop_packages["vscode-darwin-arm64"]
  | .url == ("https://update.code.visualstudio.com/" + .minimum_version + "/darwin-arm64/stable")'
assert_json "$seed" '[.versions_lock.desktop_packages[] | (.size | type == "number" and . > 0) and (.sha256 | test("^[0-9a-f]{64}$"))] | all'
assert_json "$seed" '.versions_lock.desktop_packages | .vscode.sha256 != .["vscode-darwin-arm64"].sha256'

# The fixture instance starts from the seed, as `dotsteward init` merges it.
jq -e --slurpfile seed "$seed" '. as $lock | $seed[0].versions_lock
  | [paths(scalars)] | all(. as $path | ($lock | getpath($path)) == ($seed[0].versions_lock | getpath($path)))' \
  "$vscode_fixture/versions.lock.json" >/dev/null || ds_fail "the fixture lock does not contain the vscode seed"

# The framework's seed check accepts it.
cd "$DS_REPO_ROOT"
assert_exit 0 "$DS_REPO_ROOT/cli/dotsteward" static --sandbox --only seeds
assert_contains "$DS_STDOUT" "[dotsteward] static checks passed (framework): seeds"

# seed_lock_problems FRAMEWORK: the lock-path problems of the catalog of
# FRAMEWORK (tests/static/seed-lock-paths.nix), compact JSON.
seed_lock_problems() {
  [[ -n ${DS_HOME_MANAGER:-} && -n ${nix_lib_store:-} ]] || nix_core_init
  local out=$DS_TEST_ROOT/seed-lock-paths.out err=$DS_TEST_ROOT/seed-lock-paths.err
  env -u NIX_REMOTE -u NIX_PATH \
    NIX_STORE_DIR="$nix_lib_store/store" \
    NIX_STATE_DIR="$nix_lib_store/state" \
    NIX_LOG_DIR="$nix_lib_store/log" \
    NIX_CONF_DIR="$nix_lib_store/etc" \
    NIX_LOCALSTATE_DIR="$nix_lib_store/state" \
    nix-instantiate --eval --strict --json --show-trace \
    --argstr nixpkgs "$DS_NIXPKGS" --argstr homeManager "$DS_HOME_MANAGER" --argstr repo "$1" \
    "$1/tests/static/seed-lock-paths.nix" >"$out" 2>"$err" ||
    ds_fail "lock-path evaluation of $1 failed: $(<"$err")"
  jq -c . "$out"
}

# Every lock path vscode reads (the install pins of every supported method,
# the download-pin rules) exists in the seed.
assert_eq '[]' "$(seed_lock_problems "$DS_REPO_ROOT" | jq -c 'map(select(startswith("vscode/")))')" "lock paths of vscode"

# A seed without the darwin pin is caught by that check.
fw=$DS_TEST_ROOT/fw
mkdir -p "$fw"
cp -R "$DS_REPO_ROOT/." "$fw/"
chmod -R u+w "$fw"
jq 'del(.versions_lock.desktop_packages["vscode-darwin-arm64"])' "$seed" >"$fw/modules/components/vscode/seed.json"
problems=$(seed_lock_problems "$fw")
assert_contains "$problems" "vscode/seed.json: lock path desktop_packages.vscode-darwin-arm64 read by install.app-archive.pin is missing"
assert_contains "$problems" "vscode/seed.json: lock path desktop_packages.vscode-darwin-arm64 read by pins.rules download-pin.at is missing"

# The pins engine over the fixture instance (its lock holds the seed): the
# vscode rules of the committed manifest mirrors pass.
inst=$(instance_copy "$vscode_fixture")
write_mirrors "instance { root = /. + \"$inst\"; }" "$inst"
git -C "$inst" init -q -b main
git -C "$inst" add -A
git -C "$inst" -c user.name=check -c user.email=check@example.invalid commit -q -m instance
assert_exit 0 "$DS_REPO_ROOT/cli/dotsteward" --instance "$inst" pins check
assert_not_contains "$DS_STDOUT$DS_STDERR" "Traceback"

# A pin whose URL does not carry its version fails its rule.
lock=$inst/versions.lock.json
jq --indent 2 '.desktop_packages["vscode-darwin-arm64"].url = "https://update.code.visualstudio.com/latest/darwin-arm64/stable"' \
  "$lock" >"$lock.new"
mv -- "$lock.new" "$lock"
assert_exit 1 "$DS_REPO_ROOT/cli/dotsteward" --instance "$inst" pins check
assert_contains "$DS_STDERR" "desktop_packages.vscode-darwin-arm64.url"
version=$(jq -r '.versions_lock.desktop_packages["vscode-darwin-arm64"].minimum_version' "$seed")
assert_contains "$DS_STDERR" "https://update.code.visualstudio.com/$version/darwin-arm64/stable"
