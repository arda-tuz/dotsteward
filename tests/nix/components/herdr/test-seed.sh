# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* and herdr_* variables come from the harness and helpers.sh; errexit stops a failed cd
# The herdr seed: schema version 1, valid against
# schema/seed.schema.json, one flake input whose URL, lock reference and
# version agree with each other the way the pins engine checks them
# (flake-inputs and the component's derive rule), and every lock path the
# component reads is provided by the seed.
# shellcheck source=tests/nix/components/herdr/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/herdr/helpers.sh"

seed=$herdr_component/seed.json
[[ -f $seed ]] || ds_fail "missing modules/components/herdr/seed.json"

assert_json "$seed" '.schema_version == 1 and .component == "herdr"'
assert_json "$seed" '.flake_inputs | keys == ["herdr"]'
assert_json "$seed" '.versions_lock | keys == ["flake_inputs", "nix_packages"]'

# URL, reference, version and the derived expected version agree.
assert_json "$seed" '.flake_inputs.herdr == { url: ("github:herdrdev/herdr/v" + .versions_lock.flake_inputs.herdr.version) }'
assert_json "$seed" '.versions_lock.flake_inputs.herdr.reference == .flake_inputs.herdr.url'
assert_json "$seed" '.versions_lock.flake_inputs.herdr | (.revision | test("^[0-9a-f]{40}$")) and (.nar_hash | test("^sha256-[A-Za-z0-9+/]{43}=$"))'
assert_json "$seed" '.versions_lock.flake_inputs.herdr.version | test("^[0-9]+[.][0-9]+[.][0-9]+$")'
assert_json "$seed" '.versions_lock.nix_packages.herdr == { expected: .versions_lock.flake_inputs.herdr.version, resolved: .versions_lock.flake_inputs.herdr.version }'

# The fixture instance starts from the seed, as `dotsteward init` merges it.
jq -e --slurpfile seed "$seed" '. as $lock | $seed[0].versions_lock
  | [paths(scalars)] | all(. as $path | ($lock | getpath($path)) == ($seed[0].versions_lock | getpath($path)))' \
  "$herdr_fixture/versions.lock.json" >/dev/null || ds_fail "the fixture lock does not contain the herdr seed"

# The framework's seed check accepts it.
cd "$DS_REPO_ROOT"
assert_exit 0 "$DS_REPO_ROOT/cli/dotsteward" static --sandbox --only seeds
assert_contains "$DS_STDOUT" "[dotsteward] static checks passed (framework): seeds"

# Every lock path herdr reads (flake input, derive rule) exists in the seed:
# tests/static/seed-lock-paths.nix, evaluated without the herdr input.
[[ -n ${DS_HOME_MANAGER:-} && -n ${nix_lib_store:-} ]] || nix_core_init
out=$DS_TEST_ROOT/seed-lock-paths.out
err=$DS_TEST_ROOT/seed-lock-paths.err
env -u NIX_REMOTE -u NIX_PATH \
  NIX_STORE_DIR="$nix_lib_store/store" \
  NIX_STATE_DIR="$nix_lib_store/state" \
  NIX_LOG_DIR="$nix_lib_store/log" \
  NIX_CONF_DIR="$nix_lib_store/etc" \
  NIX_LOCALSTATE_DIR="$nix_lib_store/state" \
  nix-instantiate --eval --strict --json --show-trace \
  --argstr nixpkgs "$DS_NIXPKGS" --argstr homeManager "$DS_HOME_MANAGER" --argstr repo "$DS_REPO_ROOT" \
  "$DS_REPO_ROOT/tests/static/seed-lock-paths.nix" >"$out" 2>"$err" ||
  ds_fail "lock-path evaluation failed: $(<"$err")"
assert_eq '[]' "$(jq -c 'map(select(startswith("herdr/")))' "$out")" "lock paths of herdr"

# A seed without the derived package entry is caught by that check.
fw=$DS_TEST_ROOT/fw
mkdir -p "$fw"
cp -R "$DS_REPO_ROOT/." "$fw/"
chmod -R u+w "$fw"
jq 'del(.versions_lock.nix_packages)' "$seed" >"$fw/modules/components/herdr/seed.json"
env -u NIX_REMOTE -u NIX_PATH \
  NIX_STORE_DIR="$nix_lib_store/store" \
  NIX_STATE_DIR="$nix_lib_store/state" \
  NIX_LOG_DIR="$nix_lib_store/log" \
  NIX_CONF_DIR="$nix_lib_store/etc" \
  NIX_LOCALSTATE_DIR="$nix_lib_store/state" \
  nix-instantiate --eval --strict --json \
  --argstr nixpkgs "$DS_NIXPKGS" --argstr homeManager "$DS_HOME_MANAGER" --argstr repo "$fw" \
  "$fw/tests/static/seed-lock-paths.nix" >"$out" 2>"$err" ||
  ds_fail "lock-path evaluation failed: $(<"$err")"
assert_contains "$(<"$out")" "herdr/seed.json: lock path nix_packages.herdr.expected read by pins.rules derive.to is missing"
