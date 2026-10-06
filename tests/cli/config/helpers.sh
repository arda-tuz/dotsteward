# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Helpers for the configuration tests (tests/cli/config). Not a test file.
#
#   config_py ARG...          runs the Python exporter
#                             (python3 -m dotsteward_cli.config) of the
#                             framework under test
#   config_catalog            the six public catalog names, comma-separated,
#                             as the Nix tests pass them (prelude.nix)
#   make_framework DIR [NAME...]
#                             copies cli/, schema/ and VERSION of the
#                             framework under test to DIR and creates the
#                             catalog directories modules/components/NAME
#                             (default: the six public catalog names)
#   make_instance DIR [FILE]  creates DIR with workstation.toml copied from
#                             FILE (default: the minimal Nix fixture)
#   load_config FRAMEWORK [ARG...]
#                             sources FRAMEWORK/cli/lib/lib.sh and config.sh
#                             in the current shell and runs config_load ARG...

# shellcheck disable=SC2034 # used by the test files that source this file
config_fixtures=$DS_REPO_ROOT/tests/cli/config/fixtures
nix_valid_fixtures=$DS_REPO_ROOT/tests/nix/lib/fixtures/valid
# shellcheck disable=SC2034 # used by the test files that source this file
nix_invalid_fixtures=$DS_REPO_ROOT/tests/nix/lib/fixtures/invalid

config_py() {
  PYTHONPATH=$DS_REPO_ROOT/cli/python PYTHONDONTWRITEBYTECODE=1 \
    python3 -s -P -m dotsteward_cli.config "$@"
}

config_catalog() {
  printf '%s\n' shell,herdr,claude-code,codex,opencode-pi,vscode
}

make_framework() {
  local dir=$1 name
  shift
  (($#)) || set -- shell herdr claude-code codex opencode-pi vscode
  mkdir -p "$dir/modules/components"
  cp -R "$DS_REPO_ROOT/cli" "$DS_REPO_ROOT/schema" "$DS_REPO_ROOT/VERSION" "$dir/"
  for name in "$@"; do
    mkdir -p "$dir/modules/components/$name"
  done
}

make_instance() {
  local dir=$1 file=${2:-$nix_valid_fixtures/minimal.toml}
  mkdir -p "$dir"
  cp -- "$file" "$dir/workstation.toml"
}

load_config() {
  local framework=$1
  shift
  # shellcheck source=cli/lib/lib.sh
  source "$framework/cli/lib/lib.sh"
  # shellcheck source=cli/lib/config.sh
  source "$framework/cli/lib/config.sh"
  config_load "$@"
}
