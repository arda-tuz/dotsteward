# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# An adopt-mode profile never installs a system-level component in its rebuild, so apply does it
# before the rebuild, for the system-level components the transaction adds or changes and that
# are not in place yet: on a terminal it runs `install --component` itself, which asks for sudo
# there; without a terminal it waits with the exact command (exit 3) and the commit stays local,
# and the same apply goes on once the command ran. A fresh-mode profile installs them in its
# rebuild, and a component the transaction does not touch is never installed here.
# shellcheck source=tests/apply/helpers.sh
source "$DS_REPO_ROOT/tests/apply/helpers.sh"

base=$(remote_oid)

# A system-level component outside the transaction is not installed here.
add_system_component example-old adopt
commit_all "chore: an older system component"
git -C "$up_inst" push -q origin HEAD:main
base=$(remote_oid)

# Without a terminal: the command waits for the person, before the rebuild.
add_system_component example-new adopt
clear_log
assert_exit 3 apply -m "feat: add example-new" --activate --publish
assert_order '^static ' '^install .*--component example-new.*--check-only|^install .*--check-only.*--component example-new'
assert_no_step '^install .*example-old'
assert_no_step '^rebuild '
assert_no_step '^e2e '
assert_eq "$base" "$(git -C "$up_inst" rev-parse HEAD^)" "the change is committed"
assert_eq "$base" "$(remote_oid)" "nothing is published"
review_json "[.items[] | select(.command == \"apply\" and .code == \"install-required\" and .components == [\"example-new\"]
  and .run == \"dotsteward --instance $up_inst install --profile workstation --component example-new\")] | length == 1"
assert_eq pending "$(apply_step install)"

# The person ran it: the same apply goes on.
: >"$UP_CONTROL/installed-example-new"
clear_log
assert_exit 0 apply --activate --publish
assert_order '^install .*--check-only' '^rebuild ' '^e2e '
assert_no_step '^install --profile workstation --component example-new root='
assert_eq "$(head_oid)" "$(remote_oid)"

# On a terminal apply runs the install itself, before the rebuild.
add_system_component example-third adopt
clear_log
assert_exit 0 apply_on_terminal -- -m "feat: add example-third" --activate --publish
assert_order '^install .*--check-only' "^install --profile workstation --component example-third root=$up_inst\$" '^rebuild ' '^e2e '
assert_eq "$(head_oid)" "$(remote_oid)"

# A failed install stops before the rebuild.
add_system_component example-fourth adopt
: >"$UP_CONTROL/install-fails"
clear_log
assert_exit 1 apply_on_terminal -- -m "feat: add example-fourth" --activate --publish
assert_no_step '^rebuild '
rm -f -- "$UP_CONTROL/install-fails"

# Fresh mode: the rebuild installs it, apply does not ask.
git -C "$up_inst" reset -q --hard "$(remote_oid)"
add_system_component example-fresh fresh
clear_log
assert_exit 0 apply -m "feat: add example-fresh" --activate --publish
assert_no_step '^install '
assert_order '^rebuild ' '^e2e '

# Without an activation nothing is installed.
add_system_component example-later adopt
clear_log
assert_exit 0 apply -m "feat: add example-later"
assert_no_step '^install '
