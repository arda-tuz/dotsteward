# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The first commit of `dotsteward init` has UTC dates (docs/privacy.md), whatever time zone the
# shell of the person has.
# shellcheck source=tests/instance/init/helpers.sh
source "$DS_REPO_ROOT/tests/instance/init/helpers.sh"

init_use_nix
dir=$HOME/station
TZ=UTC-3 init_run 0 --dir "$dir" --remote "$init_remote" --components shell
assert_eq "+0000 +0000" "$(git -C "$dir" log -1 --format='%ad %cd' --date=format:%z)" "the dates of the first commit"
