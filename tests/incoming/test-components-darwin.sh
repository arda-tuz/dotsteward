# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The scenarios of test-components.sh on the darwin system. `macos-smoke` runs this suite
# natively on darwin, where the mirror of each clone is .dotsteward/manifest.aarch64-darwin.json;
# a fixture that names only the mirror of x86_64-linux stops there. The platform of the CLI is
# forced here, so a Linux runner sees the same fixture.
export DOTSTEWARD_PLATFORM=darwin
# shellcheck source=tests/incoming/test-components.sh
source "$DS_REPO_ROOT/tests/incoming/test-components.sh"
