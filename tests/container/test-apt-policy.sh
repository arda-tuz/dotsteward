# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The drop-in of apt-policy and its E2E hook on the apt of each release.
# shellcheck source=tests/container/helpers.sh
source "$DS_REPO_ROOT/tests/container/helpers.sh"
container_each apt-policy
