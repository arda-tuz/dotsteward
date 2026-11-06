# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Helpers for the tests of the Python package and its primitives
# (tests/cli/core). Not a test file.
#
#   internal ARG...       the internal command line, `ds_internal ARG...` of
#                         cli/lib/python.sh, as the bash code of the
#                         framework calls it
#   core_python ARG...    python3 as the commands run it, with the package on
#                         its module path (a driver reads its script from
#                         standard input with `-`)
#   core_wait PATH        waits for PATH to exist (30 seconds at most)
#   core_instance DIR [TOML]
#                         a synthetic instance at DIR: the smallest valid
#                         workstation.toml, then the text TOML

# shellcheck source=cli/lib/python.sh
source "$DS_REPO_ROOT/cli/lib/python.sh"

internal() {
  ds_internal "$@"
}

core_python() {
  PYTHONPATH=$DS_REPO_ROOT/cli/python PYTHONDONTWRITEBYTECODE=1 python3 -s -P "$@"
}

core_instance() {
  mkdir -p "$1"
  cat >"$1/workstation.toml" <<TOML
schema_version = 1

[identity]
username = "example"

[instance]
remote = "git@github.com:example/workstation.git"

[nix]
state_version = "26.05"

[profiles]
names = ["main"]

${2:-}
TOML
}

core_wait() {
  local tries=0
  until [[ -e $1 ]]; do
    tries=$((tries + 1))
    ((tries < 1500)) || ds_fail "$1 did not appear"
    sleep 0.02
  done
}
