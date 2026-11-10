# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# The platform filter of Nix (P7): a component the manifest of this system marks unavailable
# (its platform, or its method there) is left out by every command, probes included, so gate
# and E2E stay green, and the commands say it is not available on this platform.
# shellcheck source=tests/cli/host/helpers.sh
source "$DS_REPO_ROOT/tests/cli/host/helpers.sh"

ran=$DS_TEST_ROOT/ran.log
: >"$ran"
add_component example external '{}'
manifest_edit '.checks.commands += [{ component: "example", command: "example-missing-command" }]
  | .probes += [{ component: "example", command: "example-missing-probe", kind: "presence", argv: ["--check"] }]'
add_e2e_hook example end-check late <<EOF_HOOK
printf 'e2e hook\n' >>"$ran"
EOF_HOOK
publish_instance

# Available: its missing command and probe are findings.
assert_exit 1 run_e2e --json --keep-going
assert_contains "$(findings)" '"missing-command","example-missing-command"'

# The manifest of this system leaves it out for its method.
manifest_edit '(.components[] | select(.name == "example")).unavailable = "method"'
publish_instance
assert_eq '["example"]' "$(effective .skip.components)"
assert_eq '{"component:example":"method"}' "$(effective .reasons)"
assert_exit 0 run_skills effective
assert_contains "$DS_STDOUT" "components left out: example (method)"
: >"$ran"
assert_exit 0 run_e2e
assert_contains "$DS_STDOUT$DS_STDERR" "example: not available on this platform (its method)"
assert_eq "" "$(<"$ran")" "the hook of an unavailable component does not run"
assert_exit 0 run_e2e --list
assert_not_contains "$DS_STDOUT" "example:end-check"

# And for its platform.
manifest_edit '(.components[] | select(.name == "example")).unavailable = "platform"'
publish_instance
assert_eq '{"component:example":"platform"}' "$(effective .reasons)"
assert_exit 0 run_e2e
assert_contains "$DS_STDOUT$DS_STDERR" "example: not available on this platform"
