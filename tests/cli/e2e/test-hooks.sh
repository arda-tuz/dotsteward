# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# E2E hook contract: early hooks run after the commands
# and before the managed links, main hooks after the settings checks, late
# hooks after the repository checks; within a phase in [components] order,
# then declaration order; only for components active in the profile and
# hooks whose profiles include it. Each hook gets the hook environment with
# DOTSTEWARD_CHECK_ONLY=1; a failing hook is the finding
# "component <name> hook <hook> failed (exit N)". Hook scripts resolve
# before any check runs.
# shellcheck source=tests/cli/e2e/helpers.sh
source "$DS_REPO_ROOT/tests/cli/e2e/helpers.sh"

none='{"command": null, "versionArgv": null, "minimum": null}'
add_component example-term external "$none"
add_component example-app external "$none"
add_component gamma external "$none" '["fresh"]'
for phase in late main early; do
  hook_log_script "app-$phase" | add_e2e_hook example-app "app-$phase" "$phase"
  hook_log_script "term-$phase" | add_e2e_hook example-term "term-$phase" "$phase"
done
hook_log_script app-fresh | add_e2e_hook example-app app-fresh main '["fresh"]'
hook_log_script gamma-main | add_e2e_hook gamma gamma-main main
cat <<'SH' | add_e2e_hook example-app env-dump main
{
  printf 'lib=%s\n' "$([[ -f $DOTSTEWARD_LIB/lib.sh && -f $DOTSTEWARD_LIB/platform-linux.sh ]] && echo ok)"
  printf 'instance=%s\nstate=%s\nplatform=%s\nassume_yes=%s\n' "$DOTSTEWARD_INSTANCE" \
    "$DOTSTEWARD_STATE_ROOT" "$DOTSTEWARD_PLATFORM" "$DOTSTEWARD_ASSUME_YES"
  printf 'args=%s\n' "$#"
} >"$DOTSTEWARD_STATE_ROOT/env-dump"
SH
publish_instance

assert_exit 0 run_e2e
assert_eq "term-early example-term/workstation/adopt/1
app-early example-app/workstation/adopt/1
term-main example-term/workstation/adopt/1
app-main example-app/workstation/adopt/1
term-late example-term/workstation/adopt/1
app-late example-app/workstation/adopt/1" "$(<"$e2e_hook_log")"
assert_eq "lib=ok
instance=$agents_inst
state=$DOTSTEWARD_STATE_ROOT
platform=linux
assume_yes=0
args=0" "$(<"$DOTSTEWARD_STATE_ROOT/env-dump")"

: >"$e2e_hook_log"
assert_exit 0 run_e2e --profile fresh
assert_eq "term-early example-term/fresh/fresh/1
app-early example-app/fresh/fresh/1
term-main example-term/fresh/fresh/1
app-main example-app/fresh/fresh/1
app-fresh example-app/fresh/fresh/1
gamma-main gamma/fresh/fresh/1
term-late example-term/fresh/fresh/1
app-late example-app/fresh/fresh/1" "$(<"$e2e_hook_log")"

# Phase order against the runner's own checks: failures in every phase,
# collected with --keep-going, appear in run order.
printf '#!%s\nexit 3\n' "$BASH" >"$agents_inst/components/example-term/term-early.sh"
printf '#!%s\nexit 4\n' "$BASH" >"$agents_inst/components/example-app/app-main.sh"
printf '#!%s\nexit 5\n' "$BASH" >"$agents_inst/components/example-app/app-late.sh"
manifest_edit '.managed_links = ["~/.zshrc"]'
publish_instance
printf 'scratch\n' >"$agents_inst/scratch.txt"
assert_exit 1 run_e2e --json --keep-going
assert_eq "$(jq -cn --arg home "$HOME" --arg inst "$agents_inst" '[
  ["example-term:term-early", "hook-failed", "example-term/term-early"],
  ["core:managed-links", "managed-link-missing", ($home + "/.zshrc")],
  ["example-app:app-main", "hook-failed", "example-app/app-main"],
  ["core:repo-clean", "repo-dirty", $inst],
  ["example-app:app-late", "hook-failed", "example-app/app-late"]]')" "$(findings)"
assert_json - '.findings[0].message == "component example-term hook term-early failed (exit 3)"' <<<"$DS_STDOUT"
assert_json - '.findings[2].message == "component example-app hook app-main failed (exit 4)"' <<<"$DS_STDOUT"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: e2e failed: 5 findings"

# Fail-fast: the first failing hook ends the run.
: >"$e2e_hook_log"
assert_exit 1 run_e2e
assert_contains "$DS_STDERR" "[dotsteward] ERROR: component example-term hook term-early failed (exit 3)"
assert_not_contains "$(<"$e2e_hook_log")" "main"
rm "$agents_inst/scratch.txt"

# A hook script that cannot run is refused before any check runs.
chmod 0644 "$agents_inst/components/example-app/app-late.sh"
: >"$e2e_hook_log"
assert_exit 1 run_e2e --json --keep-going
assert_eq "$(jq -cn --arg inst "$agents_inst" '[["setup", "error", ""]]')" "$(findings)"
assert_contains "$DS_STDOUT" "component example-app hook app-late: not an executable file: $agents_inst/components/example-app/app-late.sh"
assert_eq "" "$(<"$e2e_hook_log")"
assert_eq "" "$(temp_dirs)"
