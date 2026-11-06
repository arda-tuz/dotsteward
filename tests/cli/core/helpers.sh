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

# shellcheck source=cli/lib/python.sh
source "$DS_REPO_ROOT/cli/lib/python.sh"

internal() {
  ds_internal "$@"
}

core_python() {
  PYTHONPATH=$DS_REPO_ROOT/cli/python PYTHONDONTWRITEBYTECODE=1 python3 -s -P "$@"
}
