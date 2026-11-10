# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The writer of the system method against the real root of each release.
# shellcheck source=tests/container/helpers.sh
source "$DS_REPO_ROOT/tests/container/helpers.sh"
container_each system-files
