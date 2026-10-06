# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # Nix expressions and expected shell text in single quotes
# modules/core cli: the dotsteward CLI in the generation and the
# local-maintained-files alias with baked defaults and the generation's
# settings targets.
# shellcheck source=tests/nix/core/helpers.sh
source "$DS_REPO_ROOT/tests/nix/core/helpers.sh"

# The CLI and the alias are installed by default.
assert_core_eq '["dotsteward","local-maintained-files"]' \
  'lib.filter (n: lib.elem n [ "dotsteward" "local-maintained-files" ]) (packageNames (homeOf { }))'
assert_core_eq '"dotsteward"' 'lib.getName (homeOf { }).dotsteward.cli.package'
assert_core_eq 'true' '(homeOf { }).dotsteward.cli.alias'

# The CLI comes from packages.dotsteward (the instance package set, F8).
assert_core_eq '"example-cli"' \
  'lib.getName (homeOf { packages = { dotsteward = (pkgsFor "x86_64-linux").writeShellScriptBin "example-cli" ""; }; }).dotsteward.cli.package'

# Without the alias, only the CLI.
assert_core_eq '["dotsteward"]' \
  'lib.filter (n: lib.elem n [ "dotsteward" "local-maintained-files" ]) (packageNames (homeOf { modules = [ { dotsteward.cli.alias = false; } ]; }))'
assert_core_eq 'null' '(homeOf { modules = [ { dotsteward.cli.alias = false; } ]; }).dotsteward.cli.aliasPackage'

# run_alias ARGS ENV... -- ARG...: writes the alias script of the
# configuration with its CLI replaced by a recorder, runs it with the given
# environment and arguments and prints the recorded arguments, one per line.
run_alias() {
  local args=$1 script cli recorder
  shift
  script=$DS_TEST_ROOT/alias.sh
  recorder=$DS_TEST_ROOT/recorder.sh
  core_raw "(homeOf ($args)).dotsteward.cli.aliasPackage.text" >"$script"
  cli=$(core_raw "\"\${(homeOf ($args)).dotsteward.cli.package}/bin/dotsteward\"")
  printf '#!%s\nprintf "%%s\\n" "$@"\n' "$BASH" >"$recorder"
  chmod 0755 "$recorder"
  assert_contains "$(<"$script")" "exec $cli settings" "the alias runs the generation's CLI"
  sed -i "s|$cli|$recorder|" "$script"
  local env_args=()
  while (($#)) && [[ $1 != -- ]]; do
    env_args+=("$1")
    shift
  done
  [[ ${1:-} != -- ]] || shift
  env -i HOME=/home/alice PATH="$PATH" "${env_args[@]}" bash "$script" "$@"
}

targets() {
  core_raw "\"\${(homeOf ($1)).dotsteward.cli.aliasPackage.targetsFile}\""
}

workstation='{ config = "workstation"; modules = componentModules; }'
targets_file=$(targets "$workstation")

# Baked defaults: the expanded checkout and the state directory under the
# configured state root, as the engine's last-resort defaults (section 7:
# the environment and instance discovery come first, which the engine
# resolves); user arguments come last.
assert_eq "$(printf '%s\n' settings --targets-file "$targets_file" --repo-default /home/alice/workstation \
  --state-dir-default /home/alice/.local/state/workstation/local-maintained-files status --json)" \
  "$(run_alias "$workstation" -- status --json)" "baked defaults"

# The alias leaves the environment to the engine: DOTSTEWARD_INSTANCE,
# DOTSTEWARD_STATE_ROOT and the legacy DOTFILES_* names do not change its
# arguments.
assert_eq "$(printf '%s\n' settings --targets-file "$targets_file" --repo-default /home/alice/workstation \
  --state-dir-default /home/alice/.local/state/workstation/local-maintained-files apply)" \
  "$(run_alias "$workstation" DOTSTEWARD_INSTANCE=/srv/instance DOTSTEWARD_STATE_ROOT=/srv/state \
    DOTFILES_ROOT=/srv/legacy DOTFILES_STATE_ROOT=/srv/legacy-state -- apply)" \
  "environment"

# The default state root is expanded at run time, so XDG_STATE_HOME applies.
minimal_targets=$(targets '{ }')
assert_eq "$(printf '%s\n' settings --targets-file "$minimal_targets" --repo-default /home/alice/workstation \
  --state-dir-default /home/alice/.local/state/dotsteward/local-maintained-files status)" \
  "$(run_alias '{ }' -- status)" \
  "default state root"
assert_eq "$(printf '%s\n' settings --targets-file "$minimal_targets" --repo-default /home/alice/workstation \
  --state-dir-default /srv/xdg-state/dotsteward/local-maintained-files status)" \
  "$(run_alias '{ }' XDG_STATE_HOME=/srv/xdg-state -- status)" \
  "XDG_STATE_HOME"

# Without a checkout (no instance name), no baked repository.
no_checkout='{ config = dsLib.config.loadWith { catalog = testCatalog; } (fixtures + "/minimal.toml"); }'
assert_eq "$(printf '%s\n' settings --targets-file "$(targets "$no_checkout")" \
  --state-dir-default /home/alice/.local/state/dotsteward/local-maintained-files status)" \
  "$(run_alias "$no_checkout" -- status)" "no checkout"

# State roots with $VAR, ${VAR} and ~ are expanded by the shell; other shell
# syntax is refused at evaluation time.
with_root() {
  printf '{ config = let c = loadToml "minimal"; in c // { state = { root = %s; }; }; }' "$1"
}
assert_eq "$(printf '%s\n' settings --targets-file "$minimal_targets" --repo-default /home/alice/workstation \
  --state-dir-default '/srv/data/state/~x/local-maintained-files')" \
  "$(run_alias "$(with_root '"\${DATA:-~/data}/state/~x"')" DATA=/srv/data)" "default word not used"
assert_eq "$(printf '%s\n' settings --targets-file "$minimal_targets" --repo-default /home/alice/workstation \
  --state-dir-default '/home/alice/data/state/~x/local-maintained-files')" \
  "$(run_alias "$(with_root '"\${DATA:-~/data}/state/~x"')")" "tilde in the default word"
assert_eq "$(printf '%s\n' settings --targets-file "$minimal_targets" --repo-default /home/alice/workstation \
  --state-dir-default '/home/alice/state/srv/local-maintained-files')" \
  "$(run_alias "$(with_root '"$HOME/state/\${SUB}"')" SUB=srv)" "plain variables"
for root in '"$(id)/state"' '"`id`/state"' '"/state/\"quoted\""' '"/state\\\\x"' '"\${A:=x}/state"' '"\${A:-\${B}}/state"'; do
  assert_core_fails "(homeOf ($(with_root "$root"))).dotsteward.cli.aliasPackage.text" \
    "dotsteward: state.root" "unsupported shell syntax"
done

# The settings targets of the active components, rendered for the platform.
assert_core_eq "$(<"$nix_core_fixtures/targets.workstation.json")" \
  "builtins.fromJSON (homeOf $workstation).dotsteward.cli.aliasPackage.targetsFile.text"
assert_core_eq '{"schema_version":1,"targets":{"alpha":{"component":"example-app","path":"~/.config/example-app/alpha.json","format":"json","create_if_missing":true,"create_mode":"0644","backup":true,"reload":null}},"reload_hooks":{}}' \
  'builtins.fromJSON (homeOf { config = "workstation"; profile = "fresh"; modules = componentModules; }).dotsteward.cli.aliasPackage.targetsFile.text'
assert_core_eq '"~/Library/Application Support/example-term/beta.toml"' \
  '(builtins.fromJSON (homeOf { config = "workstation"; system = "aarch64-darwin"; homeDirectory = "/Users/alice"; modules = componentModules; }).dotsteward.cli.aliasPackage.targetsFile.text).targets.beta.path'
assert_core_eq '{"schema_version":1,"targets":{},"reload_hooks":{}}' \
  'builtins.fromJSON (homeOf { }).dotsteward.cli.aliasPackage.targetsFile.text'
