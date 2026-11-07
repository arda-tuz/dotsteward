#!/usr/bin/env bash
# One scenario on one disposable Ubuntu, an ordinary container without an init system, inside
# a memory limit:
#
#   tests/container/run.sh VERSION SCENARIO [ARG...]
#   tests/container/run.sh clean     removes the images of this harness
#
# VERSION is an Ubuntu release (22.04, 24.04, 26.04), SCENARIO a file of
# tests/container/scenarios. It makes the image once (tests/container/setup.sh), starts a
# container that goes away at the end, runs the scenario as a user with a password for sudo,
# under the test harness, and prints the memory peak. The exit status is the scenario's. The
# framework is mounted read only. Heavy: one at a time on a small machine.
#
# dpkg, apt and sudo need no init, and a scenario starts the daemons it wants itself. A container
# here never gets the extra rights of a system container and no device of the host: a udev inside
# such a container re-triggers every device of the machine it runs on. What truly needs systemd as
# PID 1 belongs on a CI runner or in a throwaway VM.
set -Eeuo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
IMAGE_PREFIX=dotsteward-container-test

die() {
  printf 'container: %s\n' "$*" >&2
  exit 1
}

(($# >= 1)) || die "usage: run.sh VERSION SCENARIO [ARG...] | clean"
if [[ $1 == clean ]]; then
  docker image ls --format '{{.Repository}}:{{.Tag}}' --filter "reference=$IMAGE_PREFIX" |
    while IFS= read -r image; do docker image rm --force "$image" >/dev/null; done
  exit 0
fi
(($# >= 2)) || die "usage: run.sh VERSION SCENARIO [ARG...] | clean"
version=$1
scenario=$2
shift 2
scenario_file=tests/container/scenarios/$scenario.sh
[[ -f $repo/$scenario_file ]] || die "no such scenario: $scenario"
docker image inspect "ubuntu:$version" >/dev/null 2>&1 || docker pull -q "ubuntu:$version" >/dev/null ||
  die "no image ubuntu:$version"

# A committed container and not a build: `run.sh clean` then leaves no build cache behind.
image=$IMAGE_PREFIX:$version
name=$IMAGE_PREFIX-$version-$scenario-$$
if ! docker image inspect "$image" >/dev/null 2>&1; then
  docker run --name "$name-setup" --memory=6g --memory-swap=6g --volume "$here/setup.sh:/setup.sh:ro" \
    "ubuntu:$version" bash /setup.sh || {
    docker rm --force "$name-setup" >/dev/null 2>&1 || true
    die "the image of ubuntu $version did not build"
  }
  docker commit "$name-setup" "$image" >/dev/null
  docker rm --force "$name-setup" >/dev/null
fi

finish() {
  docker exec "$name" cat /sys/fs/cgroup/memory.peak 2>/dev/null |
    awk '{printf "memory peak: %d MiB\n", $1 / 1048576}' || true
  docker rm --force "$name" >/dev/null 2>&1 || true
}
trap finish EXIT
# --init: PID 1 reaps what the scenarios kill.
docker run --detach --init --name "$name" --memory=6g --memory-swap=6g \
  --volume "$repo:/framework:ro" "$image" sleep infinity >/dev/null

docker exec --user tester --workdir /tmp "$name" bash --noprofile --norc -c \
  'source "$1"; source "$2"; ds_harness_init "$3"; shift 3; source "$DS_TEST_FILE" "$@"' bash \
  /framework/tests/lib/harness.sh /framework/tests/lib/assert.sh "/framework/$scenario_file" "$@"
