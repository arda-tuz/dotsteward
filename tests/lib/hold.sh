# shellcheck shell=bash
# hold.sh STARTED RELEASE: a process that a test keeps running on purpose, the
# child of a lock holder for example. Run it with bash, with absolute paths. It
# creates STARTED and waits for RELEASE.
#
# A test can end at any assertion, and nobody creates RELEASE then. So the wait
# also ends, with status 1, when the directory of RELEASE goes away, as the
# harness removes the root of a test when it exits, and after DS_HOLD_TIMEOUT
# seconds (default: the limit of tests/run.sh for a test file), for a test that
# was killed and removed nothing.

: >"$1"
until [[ -e $2 ]]; do
  [[ -d ${2%/*} ]] || exit 1
  ((SECONDS < ${DS_HOLD_TIMEOUT:-900})) || exit 1
  sleep 0.02
done
