# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# Helpers for the template tests (tests/instance/template): the files of the
# framework template/ (SPEC 10.1) and the template as an instance.
#
# Nix expressions are evaluated with tests/nix/instance/prelude.nix in scope
# against an isolated store (tests/nix/instance/helpers.sh), so the tests run
# the same on a developer machine and inside checks.template-static.

# shellcheck source=tests/nix/instance/helpers.sh
source "$DS_REPO_ROOT/tests/nix/instance/helpers.sh"

DS_CLI=$DS_REPO_ROOT/cli/dotsteward
tpl=$DS_REPO_ROOT/template

# A python3 with tomlkit first on PATH (the settings engine needs it): the
# one on PATH when it has tomlkit (the Nix check sandbox), else the
# framework's own interpreter (packages.<system>.dotsteward.python) built
# with Nix.
_template_use_python() {
  if python3 -c 'import tomlkit' >/dev/null 2>&1; then
    return 0
  fi
  command -v nix >/dev/null 2>&1 ||
    ds_fail "the template tests need python3 with tomlkit on PATH, or nix to build it"
  local machine system out
  machine=$(uname -m)
  case $machine in
    x86_64 | amd64) machine=x86_64 ;;
    arm64 | aarch64) machine=aarch64 ;;
  esac
  case $(uname -s) in
    Linux) system=$machine-linux ;;
    Darwin) system=$machine-darwin ;;
    *) ds_fail "unsupported system: $(uname -s)" ;;
  esac
  out=$(nix --extra-experimental-features 'nix-command flakes' build --no-link \
    --print-out-paths "$DS_REPO_ROOT#packages.$system.dotsteward.python") ||
    ds_fail "cannot build the framework python with Nix"
  mkdir -p "$DS_TEST_ROOT/python/bin"
  ln -s "$out/bin/python3" "$DS_TEST_ROOT/python/bin/python3"
  export PATH=$DS_TEST_ROOT/python/bin:$PATH
}
_template_use_python

# lock_node INPUT: the framework flake.lock node of the root input INPUT.
lock_node() {
  jq -ec --arg input "$1" '.nodes[.nodes[.root].inputs[$input]]' "$DS_REPO_ROOT/flake.lock" ||
    ds_fail "flake.lock has no root input $1"
}

# template_flake_inputs: the inputs attribute set of template/flake.nix as
# JSON (the file is imported, never evaluated as a flake).
template_flake_inputs() {
  inst_json "(import (repoRoot + \"/template/flake.nix\")).inputs"
}

# write_instance_lock DIR: writes DIR/flake.lock, what `nix flake lock` writes
# for the template (tests/instance/template/instance-lock.nix).
write_instance_lock() {
  inst_json "import (repoRoot + \"/tests/instance/template/instance-lock.nix\") {
    frameworkLock = builtins.fromJSON (builtins.readFile (repoRoot + \"/flake.lock\"));
    templateFlake = import (/. + \"$1/flake.nix\");
  }" | jq . >"$1/flake.lock"
}

# instance_expr DIR: the Nix expression of the instance at DIR.
instance_expr() {
  printf 'instance { root = /. + "%s"; }' "$1"
}

# commit_all DIR MESSAGE: commits every change of the git repository DIR.
commit_all() {
  git -C "$1" add -A
  git -C "$1" commit -q --allow-empty -m "$2"
}

# template_instance DIR: the template as `nix flake init -t` leaves it,
# copied to DIR, plus the flake.lock of the template inputs and the
# .dotsteward/ mirrors `dotsteward sync` writes, committed to a fresh git
# repository (a new instance after `dotsteward init` chose no component).
template_instance() {
  local dir=$1
  mkdir -p "$dir"
  cp -R "$tpl/." "$dir/"
  chmod -R u+w "$dir"
  write_instance_lock "$dir"
  write_mirrors "$(instance_expr "$dir")" "$dir"
  git -C "$dir" init -q -b main
  commit_all "$dir" "chore: initialize dotsteward instance"
}

# targets_file DIR SYSTEM OUT: the settings targets file of the instance DIR
# for SYSTEM, in the format of the generation's targets file, from its
# manifest mirror.
targets_file() {
  jq '{schema_version: 1, targets: .settings_targets, reload_hooks: .reload_hooks}' \
    "$1/.dotsteward/manifest.$2.json" >"$3"
}

# instance_contract DIR SYSTEM: the steps of checks.<system>.instance-contract
# (static --sandbox, whose privacy check is the instance privacy scan, the
# offline pins check and settings validate with the manifest's targets) on
# the instance DIR; every step must pass.
instance_contract() {
  local dir=$1 system=$2 targets
  targets=$DS_TEST_ROOT/targets.$system.json
  targets_file "$dir" "$system" "$targets"
  (
    cd "$dir"
    export DOTSTEWARD_INSTANCE=$dir
    assert_exit 0 "$DS_CLI" static --sandbox
    assert_exit 0 "$DS_CLI" pins check
    assert_exit 0 "$DS_CLI" settings --targets-file "$targets" validate
  )
}
