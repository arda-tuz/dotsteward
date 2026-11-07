# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# `dotsteward upgrade` with the real sudo, apt and dpkg on a terminal: both modes, the kernel series
# with no question, the bridge first, and a sudo that closes during the window.
# shellcheck source=tests/container/helpers.sh
source "$DS_REPO_ROOT/tests/container/helpers.sh"
container_each upgrade
