# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# shellcheck disable=SC2016 # the wrapper text with a literal $ is written on purpose
# The instance needs no update.sh wrapper: the launcher runs `update` and
# `gate` itself. Every static check passes for a synthetic instance without
# it, and for one that still carries a wrapper an older template wrote:
# nothing demands the file, and nothing refuses it.
# shellcheck source=tests/static/helpers.sh
source "$DS_REPO_ROOT/tests/static/helpers.sh"

command -v shellcheck >/dev/null 2>&1 || ds_fail "the static tests need shellcheck on PATH"

inst=$DS_TEST_ROOT/inst
make_instance "$inst"
cp "$DS_REPO_ROOT/template/rebuild.sh" "$DS_REPO_ROOT/template/rollback.sh" "$inst/"
commit_instance "$inst"
cd "$inst"
[[ ! -e update.sh ]] || ds_fail "the synthetic instance has an update.sh"
assert_exit 0 static
assert_contains "$DS_STDOUT" "[dotsteward] static checks passed (instance):"

# An older wrapper left in place.
printf '#!/usr/bin/env bash\nset -Eeuo pipefail\nexec "$(dirname -- "$0")/.dotsteward/cli.sh" "$@"\n' >update.sh
chmod 0755 update.sh
commit_instance "$inst"
assert_exit 0 static
assert_contains "$DS_STDOUT" "[dotsteward] static checks passed (instance):"
