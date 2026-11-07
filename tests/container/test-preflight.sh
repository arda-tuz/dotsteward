# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The fast path of a platform file in the preflight of stage 0, on the system bash and
# without jq of each release.
# shellcheck source=tests/container/helpers.sh
source "$DS_REPO_ROOT/tests/container/helpers.sh"
container_each preflight
