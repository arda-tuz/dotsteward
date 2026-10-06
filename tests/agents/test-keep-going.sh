# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# --keep-going and --json (SPEC 8.1, 6.1): --json prints one document on
# standard output, { "result": "passed|failed", "findings": [ { "step",
# "path", "code", "message" } ] }, and everything else on standard error.
# The default stays fail-fast (one finding, exit 1); --keep-going records
# each failure and goes on wherever the next step does not depend on the
# failed one: a failed layout skips the skills and the sweep, a failed skill
# only itself, while hooks, commands, floors, probes and agents checks
# always run; the exit status is 1 when anything failed.
# shellcheck source=tests/agents/helpers.sh
source "$DS_REPO_ROOT/tests/agents/helpers.sh"

ds_use_stubs example-app
none='{"command": null, "versionArgv": null, "minimum": null}'
add_component example-app external "$none"
lock_add alpha
lock_add beta
mkdir -p "$HOME/.agents/skills" "$HOME/.codex/skills"

assert_exit 0 run_agents install --json
assert_eq "$(jq -c . <<<"$DS_STDOUT")" '{"result":"passed","findings":[]}'
assert_contains "$DS_STDERR" "[dotsteward] agent tools and skills installed (profile workstation)"
assert_exit 0 run_agents check --json --keep-going
assert_eq "$(jq -c . <<<"$DS_STDOUT")" '{"result":"passed","findings":[]}'

# Independent failures: a skill (alpha, whose link-root link is then
# dangling), commands, a floor, a probe, a hook and an agents check.
rm -rf "$HOME/.agents/skills/alpha"
manifest_edit '.checks.commands = [{component: "example-app", command: "missing-one"},
    {component: "example-app", command: "missing-two"}]
  | .checks.floors = [{component: "example-app", command: "example-app", argv: ["--version"],
      minimum: "9.0", compare: "semver"}]
  | .probes = [{component: "example-app", command: "example-app", kind: "features",
      argv: ["--help"], env: {}, extract: "first-line", expected: null, needles: ["--absent"], profiles: null}]'
printf 'exit 3\n' | add_hook agents_post example-app post-fails
printf 'exit 4\n' | add_hook agents example-app check-fails

assert_exit 1 run_agents check --json
assert_eq "$(jq -c '[.result, (.findings | length), .findings[0].step, .findings[0].code]' <<<"$DS_STDOUT")" \
  '["failed",1,"skills","skill-missing"]'
assert_json - '.findings[0].path == ($ENV.HOME + "/.agents/skills/alpha")
  and (.findings[0].message | startswith("skill missing: alpha"))' <<<"$DS_STDOUT"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: skill missing: alpha"

assert_exit 1 run_agents check --json --keep-going
assert_eq "$(jq -c '[.findings[] | [.step, .code, .path]]' <<<"$DS_STDOUT")" "$(jq -cn --arg home "$HOME" '[
  ["skills", "skill-missing", ($home + "/.agents/skills/alpha")],
  ["sweep", "dangling-link", ($home + "/.claude/skills/alpha")],
  ["agents-post", "hook-failed", "example-app/post-fails"],
  ["commands", "missing-command", "missing-one"],
  ["commands", "missing-command", "missing-two"],
  ["floors", "floor-not-met", "example-app"],
  ["probes", "needle-missing", "example-app"],
  ["agents-checks", "hook-failed", "example-app/check-fails"]]')"
assert_json - '.findings[2].message == "component example-app hook post-fails failed (exit 3)"' <<<"$DS_STDOUT"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: agents check failed: 8 findings"
# beta was still verified: its link exists and is not a finding.
[[ -L $HOME/.claude/skills/beta ]] || ds_fail "beta was laid out before"

# Without --json the same findings are printed, and the exit status is 1.
assert_exit 1 run_agents check --keep-going
assert_eq "$DS_STDOUT" ""
assert_contains "$DS_STDERR" "required command not found: missing-two"
assert_contains "$DS_STDERR" "component example-app hook check-fails failed (exit 4)"

# A failed layout skips the skills and the sweep, not the rest.
mkdir "$HOME/.agents/skills/.system"
ln -s ../../.codex/skills/gone "$HOME/.agents/skills/gone"
assert_exit 1 run_agents install --json --keep-going
assert_eq "$(jq -c '[.findings[] | .step]' <<<"$DS_STDOUT")" \
  '["layout","agents-post","commands","commands","floors","probes","agents-checks"]'
[[ -L $HOME/.agents/skills/gone && ! -e $HOME/.agents/skills/alpha ]] || ds_fail "skills and sweep are skipped"
assert_eq "$(temp_dirs)" "" "no temporary directory is left behind"
