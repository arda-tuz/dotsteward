# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# Fail-fast, --keep-going and --json (SPEC 8.3, D13): by default the first
# finding ends the run with exit 1; --keep-going records every failure and
# runs every check (a missing git work tree skips only the other repository
# checks); --json prints one document { "result", "findings": [ { "step",
# "path", "code", "message" } ] } on standard output whose step is the check
# id. The agents check runs as `dotsteward agents check` and its findings are
# carried over under core:agents with their code and path, except those an
# earlier check already reported (same code and path: the agents check
# validates checks.commands too).
# shellcheck source=tests/cli/e2e/helpers.sh
source "$DS_REPO_ROOT/tests/cli/e2e/helpers.sh"

none='{"command": null, "versionArgv": null, "minimum": null}'
add_component example-app external "$none"
manifest_edit '.checks.commands = [{component: "core", command: "jq"},
    {component: "example-app", command: "missing-one"}, {component: "example-app", command: "missing-two"},
    {component: "example-app", command: "jq"}]
  | .managed_links = ["~/.zshrc"]'
lock_add alpha
publish_instance
printf 'scratch\n' >"$agents_inst/scratch.txt"

assert_exit 1 run_e2e --json
assert_eq '[["core:commands","missing-command","missing-one"]]' "$(findings)"
assert_json - '.result == "failed" and .findings[0].message == "required command not found: missing-one"' <<<"$DS_STDOUT"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: required command not found: missing-one"
assert_not_contains "$DS_STDERR" "missing-two"

assert_exit 1 run_e2e --json --keep-going
assert_eq "$(jq -cn --arg home "$HOME" --arg inst "$agents_inst" '[
  ["core:commands", "missing-command", "missing-one"],
  ["core:commands", "missing-command", "missing-two"],
  ["core:managed-links", "managed-link-missing", ($home + "/.zshrc")],
  ["core:agents", "skill-missing", ($home + "/.agents/skills/alpha")],
  ["core:repo-clean", "repo-dirty", $inst]]')" "$(findings)"
assert_json - '.findings[3].message | startswith("skills: skill missing: alpha")' <<<"$DS_STDOUT"
assert_eq 1 "$(jq -s length <<<"$DS_STDOUT")"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: e2e failed: 5 findings"

# Without --json: the same findings on standard error, nothing on standard
# output but logs.
assert_exit 1 run_e2e --keep-going
assert_not_contains "$DS_STDOUT" "{"
assert_contains "$DS_STDERR" "required command not found: missing-two"
assert_contains "$DS_STDERR" "instance checkout is not clean"

# Repaired, the run passes.
rm "$agents_inst/scratch.txt"
manifest_edit '.checks.commands = [{component: "core", command: "jq"}] | .managed_links = []'
publish_instance
assert_exit 0 run_agents install
assert_exit 0 run_e2e --json --keep-going
assert_eq '{"result":"passed","findings":[]}' "$(jq -c . <<<"$DS_STDOUT")"
assert_eq "" "$(temp_dirs)"
