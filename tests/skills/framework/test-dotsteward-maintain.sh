# shellcheck shell=bash
# shellcheck disable=SC2153 # DS_REPO_ROOT comes from tests/lib/harness.sh
# Skill contract C1-C7 for skills/dotsteward-maintain (SPEC 9.1, 9.2, 9.5):
# it hands framework and mixed requests to dotsteward-contribute and lists
# the conventional commit types the publish step accepts.
# shellcheck source=tests/skills/lib/contract.sh
source "$DS_REPO_ROOT/tests/skills/lib/contract.sh"

sc_check_framework_skill dotsteward-maintain --handover dotsteward-contribute --require-conventional-types
sc_assert_clean
