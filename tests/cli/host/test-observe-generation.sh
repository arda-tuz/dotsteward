# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# `dotsteward observe` checks what the active generation has. A deb component of the
# checkout that the active generation does not have yet (added with `maintain` and not
# rebuilt, or brought from another machine) is named and skipped until the next rebuild;
# the other components are checked as usual and the run is no failure.
# shellcheck source=tests/cli/host/observe-helpers.sh
source "$DS_REPO_ROOT/tests/cli/host/observe-helpers.sh"

add_component example-editor deb '{"packageNames": ["example-editor"]}'
hook_log_script editor-opens | add_e2e_hook example-editor editor-opens main
publish_instance "chore: one component"
pkg libexample1 1.0-1
pkg example-editor 1.2.3-1 "Depends=libexample1"
pkg example-viewer 5.0-1 "Depends=libexample1"
name_machine laptop
assert_exit 0 run_observe

# The generation of the last rebuild has one deb component; the checkout has a second.
make_generation
activate_generation
add_component example-viewer deb '{"packageNames": ["example-viewer"]}'
hook_log_script viewer-opens | add_e2e_hook example-viewer viewer-opens main
publish_instance "chore: a second component, not rebuilt yet"

pkg libexample1 1.1-1
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "example-viewer: not in the active generation yet; checked after the next rebuild"
assert_contains "$DS_STDOUT" "example-editor: verified at 1.2.3-1 (changed: libexample1)"
assert_eq "editor-opens" "$(hooks_ran)"
assert_eq '"verified"' "$(shown '.state.components["example-editor"].status')"
assert_eq '"installed"' "$(shown '.state.components["example-viewer"].status')"
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "no package changed since the last observation"

# After the rebuild the generation has it, and the next change checks it.
make_generation
pkg libexample1 1.2-1
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "example-viewer: verified at 5.0-1 (changed: libexample1)"
assert_eq $'editor-opens\nviewer-opens' "$(hooks_ran | sort)"
