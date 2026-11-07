# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# kill -9 and Ctrl-C at every step of a commit: the next run converges.
# shellcheck source=tests/container/helpers.sh
source "$DS_REPO_ROOT/tests/container/helpers.sh"
container_each interrupted
