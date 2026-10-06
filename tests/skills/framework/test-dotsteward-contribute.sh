# shellcheck shell=bash
# shellcheck disable=SC2153 # DS_REPO_ROOT comes from tests/lib/harness.sh
# Skill contract C1-C7 for skills/dotsteward-contribute (SPEC 9.1, 9.4, 9.5):
# personal parts of a request go to dotsteward-maintain.
# shellcheck source=tests/skills/lib/contract.sh
source "$DS_REPO_ROOT/tests/skills/lib/contract.sh"

sc_check_framework_skill dotsteward-contribute --handover dotsteward-maintain
sc_assert_clean
