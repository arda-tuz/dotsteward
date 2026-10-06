# shellcheck shell=bash
# shellcheck disable=SC2153 # DS_REPO_ROOT comes from tests/lib/harness.sh
# Skill contract C1-C8 for skills/dotsteward-update (SPEC 9.1, 9.3, 9.5): it
# hands framework and mixed requests to dotsteward-contribute and carries the
# framework upgrade step (release notes, input bump, one gate).
# shellcheck source=tests/skills/lib/contract.sh
source "$DS_REPO_ROOT/tests/skills/lib/contract.sh"

sc_check_framework_skill dotsteward-update --handover dotsteward-contribute --framework-upgrade
sc_assert_clean
