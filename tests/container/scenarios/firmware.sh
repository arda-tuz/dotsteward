# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Inside the container: the firmware step with the python and the terminal of this release.
apt --version | head -n 1
cd "$DS_REPO_ROOT" || exit 1
env -u DS_REPO_ROOT -u DS_TEST_FILE -u DS_TEST_ROOT DS_TEST_TIMEOUT=600 bash tests/run.sh --jobs 1 tests/cli/core/test-firmware.sh
