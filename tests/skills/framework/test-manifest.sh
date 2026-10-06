# shellcheck shell=bash
# shellcheck disable=SC2153 # DS_REPO_ROOT comes from tests/lib/harness.sh
# C9: skills/manifest.json is what tools/gen-skills-manifest.sh generates and
# lists exactly the three framework skills (the plugin skill dotsteward-init
# is distributed through the plugin channels, not by Home Manager).
# shellcheck source=tests/skills/lib/contract.sh
source "$DS_REPO_ROOT/tests/skills/lib/contract.sh"

sc_check_manifest "$DS_REPO_ROOT" dotsteward-contribute dotsteward-maintain dotsteward-update
sc_assert_clean
