# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The thin test files of tests/container (not a test file): real containers run only when
# DS_CONTAINER_VERSIONS names Ubuntu releases, because each takes minutes and needs Docker;
# every other run of the suite says SKIP.
#
#   DS_CONTAINER_VERSIONS="22.04 24.04 26.04" bash tests/run.sh tests/container
#
#   container_each SCENARIO [ARG...]   the scenario on every named release

container_each() {
  if [[ -z ${DS_CONTAINER_VERSIONS:-} ]]; then
    printf 'SKIP: set DS_CONTAINER_VERSIONS to run this in containers\n'
    exit 0
  fi
  type -P docker >/dev/null || ds_fail "DS_CONTAINER_VERSIONS is set but there is no docker"
  local version
  for version in $DS_CONTAINER_VERSIONS; do
    printf '== ubuntu %s: %s\n' "$version" "$1"
    bash "$DS_REPO_ROOT/tests/container/run.sh" "$version" "$@" || ds_fail "scenario $1 failed on ubuntu $version"
  done
}
