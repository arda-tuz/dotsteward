# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # hook scripts are single-quoted on purpose
# A component this machine leaves out is gone for every command: its hooks do not
# run, its commands and probes are not required, `e2e --list` does not name it and
# `component` refuses it. No instance can scope a component yet (skip.components
# stays empty, and the schema refuses machines and tags on a component), so a framework
# copy stands in for the release that fills it.
# shellcheck source=tests/cli/host/helpers.sh
source "$DS_REPO_ROOT/tests/cli/host/helpers.sh"

ran=$DS_TEST_ROOT/ran.log
: >"$ran"
active_answer=$DS_TEST_ROOT/active.log

add_component example external '{}'
add_component witness external '{}'
manifest_edit '.checks.commands += [{ component: "example", command: "example-missing-command" }]
  | .probes += [{ component: "example", command: "example-missing-probe", kind: "presence", argv: ["--check"] }]'
add_hook agents_post example post <<EOF_HOOK
printf 'agents_post\n' >>"$ran"
EOF_HOOK
add_hook agents example agents-check <<EOF_HOOK
printf 'agents check\n' >>"$ran"
EOF_HOOK
add_e2e_hook example end-check late <<EOF_HOOK
printf 'e2e hook\n' >>"$ran"
EOF_HOOK
# A hook of another component asks the library of hooks about it.
add_hook agents witness asks <<EOF_HOOK
source "\$DOTSTEWARD_LIB/lib.sh"
source "\$DOTSTEWARD_LIB/config.sh"
config_load "\$DOTSTEWARD_INSTANCE"
if config_component_active example workstation; then
  printf 'active\n' >"$active_answer"
else
  printf 'not active\n' >"$active_answer"
fi
EOF_HOOK
publish_instance

# The instance as it is: the component counts, so its missing commands are found.
assert_exit 1 run_e2e --json --keep-going
assert_contains "$(findings)" '"missing-command","example-missing-command"'
assert_exit 0 run_e2e --list
assert_contains "$DS_STDOUT" "example:end-check"
assert_eq "active" "$(<"$active_answer")"
assert_contains "$(<"$ran")" "agents check"
assert_contains "$(<"$ran")" "e2e hook"

# This machine leaves it out.
machine_py=$agents_fw/cli/python/dotsteward_cli/machine.py
grep -q '"components": \[\],' "$machine_py" || ds_fail "the stand-in no longer applies to machine.py"
sed -i 's/"components": \[\],/"components": ["example"],/' "$machine_py"
assert_eq '["example"]' "$(effective .skip.components)"

: >"$ran"
assert_exit 0 run_e2e --list
assert_not_contains "$DS_STDOUT" "example:"
assert_contains "$DS_STDOUT" "core:agents"
assert_exit 0 run_e2e
assert_eq "" "$(<"$ran")" "a hook of a component this machine leaves out ran"
assert_eq "not active" "$(<"$active_answer")"
assert_exit 0 run_agents install
assert_exit 0 run_agents check
assert_eq "" "$(<"$ran")" "a hook of a component this machine leaves out ran"
assert_exit 1 run_component run example post --profile workstation
assert_contains "$DS_STDERR" "component example is not active in profile workstation"

# The probes command skips its probes too.
assert_exit 0 "$agents_fw/cli/dotsteward" --instance "$agents_inst" probes --manifest "$agents_manifest" \
  --path-prefix "$DS_TEST_ROOT/no-such-directory" </dev/null
