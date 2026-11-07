# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# Activation and publishing are opt-in (K6): without an option and without [maintain] in
# workstation.toml apply gates and commits, and the commit waits locally. [maintain] activate and
# publish make "activate and publish" the default of an instance, and the options win over it.
# Publishing without an activation needs no E2E, as txn publish allows.
# shellcheck source=tests/apply/helpers.sh
source "$DS_REPO_ROOT/tests/apply/helpers.sh"

base=$(remote_oid)

# The framework default: the gate and the commit only.
edit "first"
clear_log
assert_exit 0 apply -m "docs: first"
assert_order '^static '
assert_no_step '^rebuild '
assert_no_step '^e2e '
assert_eq "$base" "$(remote_oid)" "nothing is published by default"
assert_eq "$base" "$(git -C "$up_inst" rev-parse HEAD^)"
apply_report '.data.activate == false and .data.publish == false'
apply_report '[.steps[].name] == ["stage", "gate", "commit"]'
assert_contains "$DS_STDOUT" "dotsteward apply --activate --publish"

# Publishing without an activation: no rebuild, no E2E.
clear_log
assert_exit 0 apply --publish
assert_no_step '^rebuild '
assert_no_step '^e2e '
assert_eq "$(head_oid)" "$(remote_oid)"

# The instance makes activate and publish its default, in the same transaction.
set_toml maintain activate true
set_toml maintain publish true
clear_log
assert_exit 0 apply -m "chore: activate and publish by default"
assert_order '^static ' '^rebuild ' '^e2e '
assert_eq "$(head_oid)" "$(remote_oid)"
apply_report '.data.activate == true and .data.publish == true'

# An option wins over the instance.
edit "second"
before=$(remote_oid)
clear_log
assert_exit 0 apply -m "docs: second" --no-publish
assert_order '^static ' '^rebuild ' '^e2e '
assert_eq "$before" "$(remote_oid)" "--no-publish keeps the commit local"
# Later, only the push: the E2E of the activated tree is what txn publish asks for.
clear_log
assert_exit 0 apply --no-activate --publish
assert_no_step '^rebuild '
assert_no_step '^e2e '
assert_eq "$(head_oid)" "$(remote_oid)" "the activated commit is published later"
clear_log
edit "third"
assert_exit 0 apply -m "docs: third" --no-activate --no-publish
assert_no_step '^rebuild '
assert_no_step '^e2e '

# An invalid value is refused by the configuration reader.
set_toml maintain activate '"yes"'
assert_exit 1 apply -m "docs: third"
assert_contains "$DS_STDERR" "maintain.activate"
