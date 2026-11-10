# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# A component of the system method (root-owned files, such as the drop-in of apt-policy) is
# system-level on Linux as a deb is: the rebuild of an adopt-mode profile never writes its files,
# so apply asks for `install --component` before the rebuild when the transaction adds it and its
# files are not in place.
# shellcheck source=tests/apply/helpers.sh
source "$DS_REPO_ROOT/tests/apply/helpers.sh"

base=$(remote_oid)
add_system_component example-files adopt system
clear_log
assert_exit 3 apply -m "feat: add example-files" --activate --publish
assert_order '^static ' '^install .*--component example-files.*--check-only|^install .*--check-only.*--component example-files'
assert_no_step '^rebuild '
assert_eq "$base" "$(remote_oid)" "nothing is published"
review_json "[.items[] | select(.command == \"apply\" and .code == \"install-required\" and .components == [\"example-files\"]
  and .run == \"dotsteward --instance $up_inst install --profile workstation --component example-files\")] | length == 1"

# The person ran it: the same apply goes on to the rebuild.
: >"$UP_CONTROL/installed-example-files"
clear_log
assert_exit 0 apply --activate --publish
assert_order '^install .*--check-only' '^rebuild ' '^e2e '
assert_eq "$(head_oid)" "$(remote_oid)"
