# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The validation phase (SPEC 8.1 step 7, 8.2): in both modes, the
# checks.commands of the active components must be on PATH, the
# checks.floors must hold (minimum: a version, or a lock path of
# versions.lock.json; compare: dpkg through dpkg --compare-versions, semver
# by dotted parts), then the probe registry runs for the profile. With
# --generation PATH the generation's home-path/bin goes first on PATH for
# the whole phase.
# shellcheck source=tests/agents/helpers.sh
source "$DS_REPO_ROOT/tests/agents/helpers.sh"

ds_use_stubs example-app example-term dpkg
none='{"command": null, "versionArgv": null, "minimum": null}'
add_component example-app external "$none"
add_component example-term external "$none"
add_component alpha external "$none" '["fresh"]'
manifest_edit '.checks.commands = [
    {component: "core", command: "not-a-component-command"},
    {component: "example-app", command: "example-app"},
    {component: "example-term", command: "example-term"},
    {component: "alpha", command: "alpha-only-command"}]
  | .checks.floors = [
    {component: "example-app", command: "example-app", argv: ["--version"], minimum: "1.2.0", compare: "semver"},
    {component: "example-term", command: "example-term", argv: ["--version"], minimum: "agent_tools.example-term.minimum_version", compare: "dpkg"},
    {component: "alpha", command: "example-app", argv: ["--version"], minimum: "9.0.0", compare: "semver"}]
  | .probes = [
    {component: "example-app", command: "example-app", kind: "version", argv: ["--version"], env: {},
     extract: "prefix:example-app ", expected: "versions:agent_tools.example-app.version", needles: [], profiles: null}]'
lock_set agent_tools '{"example-term": {"minimum_version": "0.9"}, "example-app": {"version": "1.2.3"}}'
ds_stub_set example-term version "example-term 1.0.0"

mkdir -p "$HOME/.agents/skills" "$HOME/.codex/skills"
assert_exit 0 run_agents check
assert_contains "$(ds_calls_of dpkg)" "dpkg --compare-versions 1.0.0 ge 0.9"

# A floor that does not hold.
lock_set agent_tools.example-term.minimum_version '"1.0.1"'
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "example-term 1.0.1 or newer is required (found 1.0.0)"
lock_set agent_tools.example-term.minimum_version '"0.9"'
ds_stub_set example-app version "example-app 1.1"
assert_exit 1 run_agents install
assert_contains "$DS_STDERR" "example-app 1.2.0 or newer is required (found 1.1)"
ds_stub_set example-app version "example-app 1.2.3"

# The probe registry.
lock_set agent_tools.example-app.version '"1.2.4"'
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "example-app version mismatch: expected 1.2.4, found 1.2.3"
lock_set agent_tools.example-app.version '"1.2.3"'

# A missing command, in the generation's bin directory only.
manifest_edit '.checks.commands += [{component: "example-term", command: "generation-tool"}]'
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "required command not found: generation-tool"
make_generation
printf '#!%s\nexit 0\n' "$BASH" >"$agents_gen/home-path/bin/generation-tool"
chmod 0755 "$agents_gen/home-path/bin/generation-tool"
assert_exit 0 run_agents check --generation "$agents_gen"

# The generation's commands come first for the floors and the probes too.
printf '#!%s\necho "example-app 1.2.3"\n' "$BASH" >"$agents_gen/home-path/bin/example-app"
chmod 0755 "$agents_gen/home-path/bin/example-app"
ds_stub_set example-app version "example-app 0.1"
assert_exit 0 run_agents check --generation "$agents_gen"
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "required command not found: generation-tool"

# The CLI's own toolchain (first on PATH and named by
# DOTSTEWARD_TOOLCHAIN_PATH in the package) is not the user's environment: a
# command, a floor command or a probe command found only there counts as
# missing.
ds_stub_set example-app version "example-app 1.2.3"
manifest_edit '.checks.commands -= [{component: "example-term", command: "generation-tool"}]'
toolchain=$DS_TEST_ROOT/toolchain
mkdir -p "$toolchain"
for tool in toolchain-command toolchain-floor toolchain-probe; do
  printf '#!%s\necho "%s 5.0.0"\n' "$BASH" "$tool" >"$toolchain/$tool"
  chmod 0755 "$toolchain/$tool"
done
manifest_edit '.checks.commands += [{component: "example-term", command: "toolchain-command"}]
  | .checks.floors += [{component: "example-term", command: "toolchain-floor", argv: ["--version"], minimum: "1.0.0", compare: "semver"}]
  | .probes += [{component: "example-term", command: "toolchain-probe", kind: "presence", argv: ["--version"], env: {},
      extract: null, expected: null, needles: [], profiles: null}]'
# Found where the user's PATH has them: everything passes.
PATH="$toolchain:$PATH" assert_exit 0 run_agents check
PATH="$toolchain:$PATH" DOTSTEWARD_TOOLCHAIN_PATH="$toolchain" assert_exit 1 run_agents check --keep-going
assert_contains "$DS_STDERR" "required command not found: toolchain-command"
assert_contains "$DS_STDERR" "required command not found: toolchain-floor"
assert_contains "$DS_STDERR" "required command not found: toolchain-probe"
