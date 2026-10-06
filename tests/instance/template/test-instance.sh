# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # bash -c scripts take their arguments as $1, $2
# The template as an instance: what `nix flake init -t` leaves, locked and
# synced, is a valid instance with no component. lib.mkInstance evaluates it
# (outputs, checks, the manifest and its current mirrors, home.nix), and it
# passes every step of the instance contract: static (shell hygiene with
# ShellCheck, the launcher and bootstrap copies, the empty skills lock, the
# versions lock policy, overlays, the privacy scan), the offline pins check,
# settings validate and the tree scan. The framework privacy scan accepts
# the template on its own as well.
# shellcheck source=tests/instance/template/helpers.sh
source "$DS_REPO_ROOT/tests/instance/template/helpers.sh"

command -v shellcheck >/dev/null 2>&1 || ds_fail "the template tests need shellcheck on PATH"

inst=$DS_TEST_ROOT/instance
template_instance "$inst"
expr=$(instance_expr "$inst")

# --- evaluation ------------------------------------------------------------------

assert_inst_eq '["dotsteward-manifest","home","home-fresh","home-workstation","instance-contract","instance-static","manifest-consistent"]' \
  "builtins.attrNames ($expr).checks.x86_64-linux" "checks of the template instance"
assert_inst_eq '["user"]' "builtins.attrNames ($expr).homeConfigurations" "homeConfigurations"
assert_inst_eq '["dotsteward","local-maintained-files"]' "builtins.attrNames ($expr).packages.x86_64-linux" \
  "packages"
assert_inst_eq '["x86_64-linux"]' "builtins.attrNames ($expr).dotstewardManifest" "systems"
assert_inst_eq '[]' "($expr).dotstewardManifest.x86_64-linux.components" "no component"
# The mirrors written above are current (checks.dotsteward-manifest), and
# the manifest is the same in both profiles (checks.manifest-consistent):
# both checks throw at evaluation otherwise.
assert_inst_eq '"dotsteward-manifest"' "($expr).checks.x86_64-linux.dotsteward-manifest.name" "current mirrors"
assert_inst_eq '"manifest-consistent"' "($expr).checks.x86_64-linux.manifest-consistent.name" "consistent manifest"

# home.nix is a module that sets nothing: the configuration of every
# profile is the one without it (home files, packages, session variables,
# activation entries).
assert_inst_eq '"lambda"' "builtins.typeOf (import (/. + \"$inst/home.nix\"))" "home.nix is a module function"
bare=$DS_TEST_ROOT/no-home-nix
cp -R "$inst" "$bare"
rm "$bare/home.nix"
facets() {
  inst_json "let c = homeOf ($1) \"x86_64-linux\" \"$2\"; in {
    files = builtins.attrNames c.home.file;
    packages = map (p: p.name) c.home.packages;
    variables = c.home.sessionVariables;
    activation = builtins.attrNames c.home.activation;
  }" | jq -S .
}
for profile in workstation fresh; do
  with_home_nix=$(facets "$expr" "$profile")
  assert_json - '.files | length > 0' "the $profile configuration has home files" <<<"$with_home_nix"
  assert_eq "$(facets "$(instance_expr "$bare")" "$profile")" "$with_home_nix" "home.nix sets nothing ($profile)"
done

# --- the instance contract ---------------------------------------------------------

instance_contract "$inst" x86_64-linux

# The same with a darwin system added (the mirrors of both systems).
darwin=$DS_TEST_ROOT/darwin
cp -R "$inst" "$darwin"
sed -i 's/^systems = \["x86_64-linux"\]$/systems = ["x86_64-linux", "aarch64-darwin"]/' "$darwin/workstation.toml"
grep -qx 'systems = \["x86_64-linux", "aarch64-darwin"\]' "$darwin/workstation.toml" ||
  ds_fail "the systems line of template/workstation.toml changed shape"
rm -f "$darwin"/.dotsteward/manifest.*.json "$darwin"/.dotsteward/stage0.*.env
write_mirrors "$(instance_expr "$darwin")" "$darwin"
commit_all "$darwin" "chore: add darwin"
assert_eq "cli.sh manifest.aarch64-darwin.json manifest.x86_64-linux.json stage0.darwin.env stage0.linux.env" \
  "$(cd "$darwin/.dotsteward" && echo *)" "mirrors of both systems"
instance_contract "$darwin" aarch64-darwin

# --- an instance static script: the tests/README.md example ----------------------

# As written in the README, with [gate] static: it passes, and its fail
# reports through the helper the static check provides.
scripted=$DS_TEST_ROOT/scripted
cp -R "$inst" "$scripted"
bash "$DS_REPO_ROOT/tests/instance/template/readme-example.sh" "$tpl/tests/README.md" "$scripted/tests/static.sh"
printf '\n[gate]\nstatic = ["tests/static.sh"]\n' >>"$scripted/workstation.toml"
rm -f "$scripted"/.dotsteward/manifest.*.json "$scripted"/.dotsteward/stage0.*.env
write_mirrors "$(instance_expr "$scripted")" "$scripted"
commit_all "$scripted" "test: add an instance static script"
instance_contract "$scripted" x86_64-linux
assert_exit 0 "$DS_CLI" --instance "$scripted" static --only scripts
assert_contains "$DS_STDOUT$DS_STDERR" "instance script tests/static.sh passed"
rm "$scripted/home/AGENTS.md"
commit_all "$scripted" "test: remove the agent rules"
assert_exit 1 "$DS_CLI" --instance "$scripted" static --only scripts
assert_contains "$DS_STDERR" "[dotsteward] ERROR: home/AGENTS.md is missing"
assert_contains "$DS_STDERR" "instance script tests/static.sh failed (exit 1)"

# --- privacy -------------------------------------------------------------------------

# The template alone, with the framework policy: no secret, home path,
# private address, non-ASCII byte or forbidden path.
copy=$DS_TEST_ROOT/template-copy
mkdir -p "$copy"
cp -R "$tpl/." "$copy/"
assert_exit 0 bash -c 'cd "$1" && "$2" scan --tree' _ "$copy" "$DS_CLI"
assert_contains "$DS_STDOUT" "scan clean"
