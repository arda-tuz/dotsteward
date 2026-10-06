# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Helpers for the bash library tests (tests/cli/lib). Not a test file.
#
# Sourcing this file sources cli/lib/lib.sh of the framework under test (and
# through it cli/lib/platform-linux.sh on Linux) into the test process.
#
#   lib_dir                    the cli/lib directory under test
#   in_lib_shell SCRIPT [ARG...]
#                              runs SCRIPT in a fresh bash that sourced
#                              lib.sh (for code that must start without the
#                              test's own state); ARG... are $1...

lib_dir=$DS_REPO_ROOT/cli/lib
# shellcheck source=cli/lib/lib.sh
source "$lib_dir/lib.sh"

in_lib_shell() {
  local script=$1
  shift
  bash --noprofile --norc -c "source \"\$0\"; $script" "$lib_dir/lib.sh" "$@"
}
