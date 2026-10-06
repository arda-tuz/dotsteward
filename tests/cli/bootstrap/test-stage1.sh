# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# dotsteward bootstrap --profile P --stage 1 (SPEC 6.2, port of
# bootstrap.sh:91-99): what stage-0 execs once Nix is there. In order: the
# system-install phase (`dotsteward install`), `rebuild --switch`,
# `login-shell set`, the desktopApply hooks of the switched generation
# (fresh mode only; adopt mode skips them with one line, D14), `e2e`, then
# the final message. The first failing step stops it with its exit status.
# The profile must be profiles.bootstrap; without --stage 1 the command
# refuses and points at ./bootstrap.sh (stage-0 is the instance script).
# The four commands it runs are recording stand-ins here; their own suites
# cover them.
# shellcheck source=tests/cli/bootstrap/helpers.sh
source "$DS_REPO_ROOT/tests/cli/bootstrap/helpers.sh"

manifest=$bs_inst/.dotsteward/manifest.x86_64-linux.json
generation=$DS_TEST_ROOT/generation
hm_profile=$HOME/.local/state/nix/profiles/home-manager

# A component with two desktopApply hooks (the second only in the adopt
# profile) that record their hook environment. They are in the manifest of
# the generation that rebuild switches to; the mirror has none, because the
# switched generation's manifest is the one that counts.
printf '\n[components.example]\nenable = true\n' >>"$bs_inst/workstation.toml"
mkdir -p "$bs_inst/components/example"
for hook in apply-desktop adopt-only; do
  cat >"$bs_inst/components/example/$hook.sh" <<EOF
#!$BASH
source $(printf %q "$DS_REPO_ROOT/tests/lib/harness.sh")
ds_record_call hook-$hook "\$@" "\$DOTSTEWARD_PROFILE" "\$DOTSTEWARD_PROFILE_MODE" "\$DOTSTEWARD_COMPONENT" \\
  "\$DOTSTEWARD_CHECK_ONLY" "\$DOTSTEWARD_INSTANCE"
if [[ -f \$DS_TEST_ROOT/exit-hook ]]; then
  exit "\$(<"\$DS_TEST_ROOT/exit-hook")"
fi
EOF
  chmod 0755 "$bs_inst/components/example/$hook.sh"
done
jq '.components += [{
    name: "example", source: "instance", method: "external", profiles: null, platforms: null,
    options: {}, modes: { workstation: "adopt", fresh: "fresh" },
    supported_methods: { linux: ["external"], darwin: ["external"] }, install: {}
  }]' "$manifest" >"$DS_TEST_ROOT/mirror.json"
jq '.hooks.desktop_apply += [
    { component: "example", name: "apply-desktop", phase: "main", profiles: null,
      script: "<instance>/components/example/apply-desktop.sh" },
    { component: "example", name: "adopt-only", phase: "main", profiles: ["workstation"],
      script: "<instance>/components/example/adopt-only.sh" }
  ]' "$DS_TEST_ROOT/mirror.json" >"$DS_TEST_ROOT/generation-manifest.json"
mv "$DS_TEST_ROOT/mirror.json" "$manifest"
instance_commit "example component"

# Recording stand-ins for install, rebuild, login-shell and e2e: each
# records "dotsteward-<command> ARG..." and exits with the content of
# DS_TEST_ROOT/exit-<command> (default 0). rebuild also switches to a
# generation with the hooks above.
for command in install rebuild login-shell e2e; do
  {
    printf '# summary: stand-in %s of the bootstrap tests\n' "$command"
    printf 'source %q\n' "$DS_REPO_ROOT/tests/lib/harness.sh"
    printf 'ds_record_call dotsteward-%s "$@"\n' "$command"
    if [[ $command == rebuild ]]; then
      printf 'mkdir -p %q %q\n' "$generation/home-path/share/dotsteward" "$(dirname "$hm_profile")"
      printf 'cp %q %q\n' "$DS_TEST_ROOT/generation-manifest.json" \
        "$generation/home-path/share/dotsteward/manifest.json"
      printf 'ln -sfn %q %q\n' "$generation" "$hm_profile"
    fi
    printf 'if [[ -f %q ]]; then\n' "$DS_TEST_ROOT/exit-$command"
    printf '  exit "$(<%q)"\n' "$DS_TEST_ROOT/exit-$command"
    printf 'fi\n'
  } >"$bs_fw/cli/commands/$command.sh"
done

final="[dotsteward] bootstrap complete for profile fresh; log out and back in once so the new login shell and desktop session take effect"

# --- the order ----------------------------------------------------------------------
assert_exit 0 run_bootstrap --profile fresh --stage 1
assert_calls \
  "dotsteward-install --profile fresh" \
  "dotsteward-rebuild --profile fresh --switch" \
  "dotsteward-login-shell set --profile fresh" \
  "hook-apply-desktop fresh fresh example 0 $bs_inst" \
  "dotsteward-e2e --profile fresh"
assert_eq "$final" "$(tail -n 1 <<<"$DS_STDOUT")"

# --- failures stop it with the step's status ----------------------------------------
# step_fails COMMAND STATUS CALLS...: COMMAND exits STATUS; bootstrap exits
# STATUS after exactly CALLS.
step_fails() {
  local command=$1 status=$2
  shift 2
  : >"$DS_CALL_LOG"
  printf '%s\n' "$status" >"$DS_TEST_ROOT/exit-$command"
  assert_exit "$status" run_bootstrap --profile fresh --stage 1
  assert_calls "$@"
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: bootstrap stopped: dotsteward $command failed (exit $status)"
  assert_not_contains "$DS_STDOUT" "bootstrap complete"
  rm "$DS_TEST_ROOT/exit-$command"
}
# The system-install phase stops on the adaptive route (preflight exit 3).
step_fails install 3 "dotsteward-install --profile fresh"
step_fails rebuild 7 "dotsteward-install --profile fresh" "dotsteward-rebuild --profile fresh --switch"
step_fails login-shell 1 "dotsteward-install --profile fresh" "dotsteward-rebuild --profile fresh --switch" \
  "dotsteward-login-shell set --profile fresh"
: >"$DS_CALL_LOG"
printf '4\n' >"$DS_TEST_ROOT/exit-hook"
assert_exit 4 run_bootstrap --profile fresh --stage 1
assert_contains "$DS_STDERR" "[dotsteward] ERROR: component example hook apply-desktop failed (exit 4)"
assert_eq 0 "$(ds_call_count dotsteward-e2e)" "no e2e after a failed hook"
rm "$DS_TEST_ROOT/exit-hook"
step_fails e2e 1 "dotsteward-install --profile fresh" "dotsteward-rebuild --profile fresh --switch" \
  "dotsteward-login-shell set --profile fresh" "hook-apply-desktop fresh fresh example 0 $bs_inst" \
  "dotsteward-e2e --profile fresh"

# --- adopt mode: no desktop apply -----------------------------------------------------
sed -i 's/^bootstrap = "fresh"$/bootstrap = "workstation"/' "$bs_inst/workstation.toml"
instance_commit "adopt bootstrap profile"
: >"$DS_CALL_LOG"
assert_exit 0 run_bootstrap --profile workstation --stage 1
assert_calls \
  "dotsteward-install --profile workstation" \
  "dotsteward-rebuild --profile workstation --switch" \
  "dotsteward-login-shell set --profile workstation" \
  "dotsteward-e2e --profile workstation"
assert_contains "$DS_STDOUT" "[dotsteward] workstation (adopt mode): desktop apply skipped"
sed -i 's/^bootstrap = "workstation"$/bootstrap = "fresh"/' "$bs_inst/workstation.toml"
instance_commit "fresh bootstrap profile"

# --- refusals: nothing runs -----------------------------------------------------------
: >"$DS_CALL_LOG"
assert_exit 1 run_bootstrap --profile fresh
assert_eq "[dotsteward] ERROR: bootstrap: stage 0 is the instance's ./bootstrap.sh; run './bootstrap.sh --profile fresh' in $bs_inst (--stage 1 is internal)" \
  "$DS_STDERR"
assert_exit 1 run_bootstrap --profile fresh --stage 2
assert_eq "[dotsteward] ERROR: bootstrap: unsupported stage: 2 (only stage 1 runs in the CLI)" "$DS_STDERR"
assert_exit 1 run_bootstrap --profile workstation --stage 1
assert_eq "[dotsteward] ERROR: bootstrap: --profile must be the bootstrap profile fresh (profiles.bootstrap), not workstation" \
  "$DS_STDERR"
assert_exit 1 run_bootstrap --profile nope --stage 1
assert_eq "[dotsteward] ERROR: unsupported profile: nope (profiles: workstation, fresh)" "$DS_STDERR"
assert_exit 1 run_bootstrap --stage 1
assert_eq "[dotsteward] ERROR: bootstrap: --profile is required" "$DS_STDERR"
assert_exit 1 run_bootstrap --profile fresh --stage
assert_eq "[dotsteward] ERROR: bootstrap: --stage requires a value" "$DS_STDERR"
assert_exit 1 run_bootstrap --profile fresh --stage 1 --bogus
assert_eq "[dotsteward] ERROR: bootstrap: unknown option: --bogus" "$DS_STDERR"
assert_exit 1 env USER='Bad User' "$bs_fw/cli/dotsteward" --instance "$bs_inst" bootstrap --profile fresh --stage 1
assert_contains "$DS_STDERR" "unsafe user name"
assert_calls
# A desktop hook that cannot run is refused before it starts.
chmod 0644 "$bs_inst/components/example/apply-desktop.sh"
assert_exit 1 run_bootstrap --profile fresh --stage 1
assert_contains "$DS_STDERR" "component example hook apply-desktop: not an executable file"
assert_eq 0 "$(ds_call_count hook-apply-desktop)" "no hook ran"
assert_eq 0 "$(ds_call_count dotsteward-e2e)" "no e2e"
chmod 0755 "$bs_inst/components/example/apply-desktop.sh"

assert_exit 0 run_bootstrap --help
assert_contains "$DS_STDOUT" "Usage: dotsteward bootstrap --profile PROFILE --stage 1"
