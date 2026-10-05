# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# nix for the fast suite: records argv, a canned --version, fake build
# outputs with an activate script and home-path/bin stubs, canned evals.

ds_use_stubs nix

assert_eq "nix (Nix) 2.31.2" "$(nix --version)"
ds_stub_set nix version "nix (Nix) 2.30.0"
assert_eq "nix (Nix) 2.30.0" "$(nix --extra-experimental-features 'nix-command flakes' --version)"

# build --print-out-paths --no-link: one fake store path per installable,
# stable for the same installable, with the generation layout.
: >"$DS_CALL_LOG"
out=$(nix --extra-experimental-features 'nix-command flakes' build \
  "/instance#homeConfigurations.default.activationPackage" --no-link --no-update-lock-file \
  --print-out-paths)
assert_calls "nix --extra-experimental-features nix-command\\ flakes build /instance#homeConfigurations.default.activationPackage --no-link --no-update-lock-file --print-out-paths"
[[ $out == "$DS_STUB_STATE/nix/store/"*-activationPackage ]] || ds_fail "unexpected out path: $out"
[[ $(basename "$out") =~ ^[0-9a-z]{32}-activationPackage$ ]] || ds_fail "store path shape: $out"
[[ -x $out/activate ]] || ds_fail "activate script missing"
[[ -d $out/home-files ]] || ds_fail "home-files missing"
[[ ! -e result ]] || ds_fail "--no-link created a result link"
assert_eq "$out" "$(nix build "/instance#homeConfigurations.default.activationPackage" --no-link --print-out-paths)"
other=$(nix build "/instance#checks.x86_64-linux.home" --no-link --print-out-paths)
[[ $other != "$out" ]] || ds_fail "different installables share a store path"

# home-path/bin holds the application stubs, which record calls themselves.
for name in claude codex herdr opencode pi code example-app example-term; do
  [[ -x $out/home-path/bin/$name ]] || ds_fail "home-path/bin/$name missing"
done
: >"$DS_CALL_LOG"
"$out/home-path/bin/example-app" --version >/dev/null
assert_calls "example-app --version"
ds_stub_set nix home-bin "example-term pi"
narrow=$(nix build "/instance#narrow" --no-link --print-out-paths)
assert_eq "example-term pi" "$(cd "$narrow/home-path/bin" && printf '%s ' * | sed 's/ $//')"

# The fake activate script only records its call.
: >"$DS_CALL_LOG"
HOME_MANAGER_BACKUP_EXT=bak "$out/activate" --driver-version 1
assert_calls "activate --driver-version 1" "activate:env HOME_MANAGER_BACKUP_EXT=bak"

# A template directory is copied into every new output.
mkdir -p "$DS_STUB_STATE/nix/output-template/home-files/.config"
printf 'templated\n' >"$DS_STUB_STATE/nix/output-template/home-files/.config/example.conf"
templated=$(nix build "/instance#templated" --no-link --print-out-paths)
assert_eq templated "$(<"$templated/home-files/.config/example.conf")"

# Default result link, --out-link, -o and --json.
nix build "/instance#withLink"
[[ -L result && -x result/activate ]] || ds_fail "default result link missing"
nix build "/instance#withLink" --out-link "$TMPDIR/gen"
assert_eq "$(readlink result)" "$(readlink "$TMPDIR/gen")"
nix build -o "$TMPDIR/gen2" "/instance#withLink"
[[ -L $TMPDIR/gen2 ]] || ds_fail "-o link missing"
assert_json - '.[0].outputs.out | endswith("-withLink")' <<<"$(nix build --json --no-link "/instance#withLink")"

# Canned failures through routes; evals need a route.
ds_stub_route nix 'build *#broken*' --exit 1 --stderr "error: builder failed with exit code 2"
assert_exit 1 nix build "/instance#broken" --no-link --print-out-paths
assert_contains "$DS_STDERR" "builder failed"
assert_exit 1 nix eval --raw "/instance#lib.version"
assert_contains "$DS_STDERR" "nix stub: no canned response for: eval --raw /instance#lib.version"
ds_stub_route nix 'eval --raw *#lib.version' --stdout "0.0.0"
assert_eq 0.0.0 "$(nix eval --raw "/instance#lib.version")"

# Flake maintenance commands succeed and are recorded.
: >"$DS_CALL_LOG"
nix flake check /instance --no-update-lock-file --keep-going -L
nix flake lock /instance
nix flake update example-input --flake /instance
assert_call_count 3 nix 'flake *'
assert_json - '.locks.nodes | type == "object"' <<<"$(nix flake metadata --json /instance)"
assert_exit 1 nix frobnicate
assert_contains "$DS_STDERR" "nix stub: unsupported command: frobnicate"
