# shellcheck shell=bash
# shellcheck disable=SC2153 # DS_REPO_ROOT comes from tests/lib/harness.sh
# Skill contract C1-C6 for the plugin skill
# plugins/dotsteward/skills/dotsteward-init (SPEC 9.1, 9.7) and C10: the
# plugin holds exactly this skill, and the plugin manifests and marketplace
# entries that exist carry VERSION. The overlay precedence sentence and the
# classification step (C7) belong to the three framework skills only: this
# skill runs before an instance, and with it any overlay, exists.
# shellcheck source=tests/skills/lib/contract.sh
source "$DS_REPO_ROOT/tests/skills/lib/contract.sh"

sc_check_plugin_skill dotsteward-init
sc_check_plugin "$DS_REPO_ROOT"
sc_assert_clean
