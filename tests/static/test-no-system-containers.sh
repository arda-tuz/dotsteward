# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# No test and no document runs a container with the rights of the machine: not the flag that
# gives them all, no device or kernel directory of the host mounted in. A udev started in such
# a container re-triggers every device of the machine and takes the desktop session with it.
# dpkg and apt work in an ordinary container; what truly needs systemd as PID 1 belongs on a CI
# runner or in a throwaway VM (docs/testing.md). The patterns are written so that this file does
# not match itself.
# shellcheck source=tests/static/helpers.sh
source "$DS_REPO_ROOT/tests/static/helpers.sh"

# system_container_hits ROOT: "path:line:text" for every file below ROOT/tests and ROOT/docs that
# gives a container more than an ordinary one has.
system_container_hits() {
  (cd "$1" && grep -rnIE -e '--privi[l]eged' -e '(-v|--volume)[ =]"?/(dev|sys)(/[^: ]*)?:' -e 'source=/(dev|sys)(/[^, ]*)?,' -- tests docs) || true
}

# It looks at the real tree, not at nothing.
[[ -d $DS_REPO_ROOT/tests/lib && -f $DS_REPO_ROOT/docs/testing.md ]] || ds_fail "no tree to look at"

# And it can find what it looks for.
fake=$DS_TEST_ROOT/fake
mkdir -p "$fake/tests/container" "$fake/docs"
flag=--privi
flag+=leged
printf 'docker run --detach %s image\n' "$flag" >"$fake/tests/container/run.sh"
source=source=
printf 'docker run --volume %s:/dev image\n' /dev >"$fake/docs/guide.md"
printf 'docker run --mount type=bind,%s/sys,target=/sys image\n' "$source" >>"$fake/docs/guide.md"
found=$(system_container_hits "$fake")
assert_contains "$found" "tests/container/run.sh:1:"
assert_contains "$found" "docs/guide.md:1:"
assert_contains "$found" "docs/guide.md:2:"

assert_eq "" "$(system_container_hits "$DS_REPO_ROOT")" "a container with the rights of the machine"
