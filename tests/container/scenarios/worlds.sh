# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Inside the container: the rootless worlds on the apt of this release.
apt --version | head -n 1
/usr/bin/python3 --version
cd "$DS_REPO_ROOT" || exit 1
env -u DS_REPO_ROOT -u DS_TEST_FILE -u DS_TEST_ROOT DS_TEST_TIMEOUT=1200 bash tests/run.sh --jobs 2 tests/apt-worlds
