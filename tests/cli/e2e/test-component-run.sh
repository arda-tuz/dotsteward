# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# `dotsteward component run NAME HOOK [--profile P] [--generation PATH]
# [-- ARG...]` (SPEC 6.2, 8.4): runs one hook of a component, found by name
# in every hook list of the manifest (hooks.* and checks.e2e/agents), with
# the hook environment (DOTSTEWARD_CHECK_ONLY=0) and the given arguments;
# the profile is --profile, else the current profile recorded in
# <state>/current/profile, else profiles.check. The exit status is the
# hook's. The component must be enabled and active in the profile; a hook
# name that names different scripts in two lists is ambiguous.
# shellcheck source=tests/cli/e2e/helpers.sh
source "$DS_REPO_ROOT/tests/cli/e2e/helpers.sh"

none='{"command": null, "versionArgv": null, "minimum": null}'
add_component example-app external "$none"
add_component gamma external "$none" '["fresh"]'
cat <<'SH' | add_hook post_install example-app host
printf 'env %s %s %s %s\n' "$DOTSTEWARD_COMPONENT" "$DOTSTEWARD_PROFILE" "$DOTSTEWARD_PROFILE_MODE" \
  "$DOTSTEWARD_CHECK_ONLY"
printf 'lib %s\n' "$([[ -f $DOTSTEWARD_LIB/lib.sh ]] && echo ok)"
printf 'arg [%s]\n' "$@"
exit "${HOST_EXIT:-0}"
SH
printf 'echo gamma-hook\n' | add_hook system_install gamma setup
printf 'echo e2e-hook\n' | add_e2e_hook example-app smoke main
publish_instance

assert_exit 0 run_component --help
assert_contains "$DS_STDOUT" "Usage: dotsteward component run NAME HOOK"
assert_exit 1 run_component
assert_contains "$DS_STDERR" "component: run is required"
assert_exit 1 run_component list
assert_contains "$DS_STDERR" "component: unknown subcommand: list"
assert_exit 1 run_component run example-app
assert_contains "$DS_STDERR" "component run: NAME and HOOK are required"
assert_exit 1 run_component run example-app host extra
assert_contains "$DS_STDERR" "component run: unexpected argument: extra (pass hook arguments after --)"
assert_exit 1 run_component run example-app host --verbose
assert_contains "$DS_STDERR" "component run: unknown option: --verbose"
assert_exit 1 run_component run example-app host --profile elsewhere
assert_contains "$DS_STDERR" "unsupported profile: elsewhere"

# Default profile (profiles.check), arguments after --.
assert_exit 0 run_component run example-app host -- --profile workstation --check-only 'two words'
assert_eq "env example-app workstation adopt 0
lib ok
arg [--profile]
arg [workstation]
arg [--check-only]
arg [two words]" "$DS_STDOUT"

# The recorded current profile, then --profile.
mkdir -p "$DOTSTEWARD_STATE_ROOT/current"
printf 'fresh\n' >"$DOTSTEWARD_STATE_ROOT/current/profile"
assert_exit 0 run_component run example-app host
assert_eq "env example-app fresh fresh 0
lib ok
arg []" "$DS_STDOUT"
assert_exit 0 run_component run --profile workstation example-app host
assert_contains "$DS_STDOUT" "env example-app workstation adopt 0"
rm "$DOTSTEWARD_STATE_ROOT/current/profile"

# The hook's exit status is the command's.
assert_exit 7 env HOST_EXIT=7 "$agents_fw/cli/dotsteward" --instance "$agents_inst" component run example-app host
assert_contains "$DS_STDERR" "[dotsteward] ERROR: component example-app hook host failed (exit 7)"

# Hooks of every list are found; an E2E check hook runs with
# DOTSTEWARD_CHECK_ONLY=0 here too.
assert_exit 0 run_component run example-app smoke
assert_eq "e2e-hook" "$DS_STDOUT"

# Unknown names, inactive components, ambiguous names.
assert_exit 1 run_component run delta host
assert_contains "$DS_STDERR" "component run: component delta is not enabled in this instance"
assert_exit 1 run_component run example-app nope
assert_contains "$DS_STDERR" "component run: component example-app has no hook nope"
assert_exit 1 run_component run gamma setup
assert_contains "$DS_STDERR" "component run: component gamma is not active in profile workstation"
assert_exit 0 run_component run gamma setup --profile fresh
assert_eq "gamma-hook" "$DS_STDOUT"
# The same name in another list and the same script is one hook.
manifest_edit '.hooks.agents_post = [.checks.e2e[0] | .phase = "main"]'
publish_instance
assert_exit 0 run_component run example-app smoke
assert_eq "e2e-hook" "$DS_STDOUT"
# The same name with another script is ambiguous.
printf 'echo other\n' | add_hook agents_post example-app smoke-post
manifest_edit '.hooks.agents_post = [.hooks.agents_post[1] | .name = "smoke"]'
publish_instance
assert_exit 1 run_component run example-app smoke
assert_contains "$DS_STDERR" "component run: hook smoke of component example-app is ambiguous (checks.e2e, hooks.agents_post)"

# A store path needs a built generation.
manifest_edit '.hooks.post_install[0].script = "<store>/host"'
publish_instance
assert_exit 1 run_component run example-app host
assert_contains "$DS_STDERR" "pass --generation with a built generation"
make_generation
jq --arg script "$agents_inst/components/example-app/host.sh" '.hooks.post_install[0].script = $script' \
  "$agents_manifest" >"$agents_gen/home-path/share/dotsteward/manifest.json"
assert_exit 0 run_component run example-app host --generation "$agents_gen"
assert_contains "$DS_STDOUT" "env example-app workstation adopt 0"
assert_eq "" "$(temp_dirs)"
