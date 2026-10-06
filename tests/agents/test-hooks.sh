# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Component hooks of the agents phase (SPEC 8.1, 8.4, D10): agentsInstall
# before the layout, agentsMigrate after the dangling sweep, agentsPost
# before the validation, checks.agents last in the validation; within a list
# in [components] order, then in declaration order; only components active
# in the profile and hooks whose profiles include it. Every list runs in
# both modes with the hook environment (DOTSTEWARD_CHECK_ONLY 0 for
# install, 1 for check). A failing hook stops the command with
# "component <name> hook <hook> failed (exit N)".
# shellcheck source=tests/agents/helpers.sh
source "$DS_REPO_ROOT/tests/agents/helpers.sh"

none='{"command": null, "versionArgv": null, "minimum": null}'
add_component example-term external "$none"
add_component example-app external "$none"
add_component alpha external "$none" '["fresh"]'
order=$DS_TEST_ROOT/order
lock_add beta
mkdir -p "$HOME/.agents/skills"
ln -s ../../.codex/skills/gone "$HOME/.agents/skills/gone"

# record TEXT: a hook body that appends TEXT, the check-only flag and
# whether the layout and the sweep already ran.
record() {
  cat <<EOF
printf '%s check=%s component=%s profile=%s mode=%s layout=%s swept=%s\n' $(printf %q "$1") \
  "\$DOTSTEWARD_CHECK_ONLY" "\$DOTSTEWARD_COMPONENT" "\$DOTSTEWARD_PROFILE" "\$DOTSTEWARD_PROFILE_MODE" \
  "\$([[ -e \$HOME/.claude/skills/beta ]] && echo yes || echo no)" \
  "\$([[ -L \$HOME/.agents/skills/gone ]] && echo no || echo yes)" >>$(printf %q "$order")
[[ -f \$DOTSTEWARD_LIB/lib.sh ]]
EOF
}
record "app post" | add_hook agents_post example-app app-post
record "term install" | add_hook agents_install example-term term-install
record "app install" | add_hook agents_install example-app app-install
record "term migrate" | add_hook agents_migrate example-term term-migrate
record "term check" | add_hook agents example-term term-check
record "app check" | add_hook agents example-app app-check
record "term post" | add_hook agents_post example-term term-post
record "term install fresh only" | add_hook agents_install example-term term-fresh '["fresh"]'
record "alpha install" | add_hook agents_install alpha alpha-install

assert_exit 0 run_agents install
assert_eq "$(cat "$order")" "term install check=0 component=example-term profile=workstation mode=adopt layout=no swept=no
app install check=0 component=example-app profile=workstation mode=adopt layout=no swept=no
term migrate check=0 component=example-term profile=workstation mode=adopt layout=yes swept=yes
term post check=0 component=example-term profile=workstation mode=adopt layout=yes swept=yes
app post check=0 component=example-app profile=workstation mode=adopt layout=yes swept=yes
term check check=0 component=example-term profile=workstation mode=adopt layout=yes swept=yes
app check check=0 component=example-app profile=workstation mode=adopt layout=yes swept=yes"

: >"$order"
assert_exit 0 run_agents check
assert_eq "$(cut -d' ' -f1-3 "$order")" "term install check=1
app install check=1
term migrate check=1
term post check=1
app post check=1
term check check=1
app check check=1"

# A failing hook stops the command.
printf 'echo "hook says no" >&2\nexit 7\n' | add_hook agents_migrate example-app app-fails
: >"$order"
assert_exit 1 run_agents install
assert_contains "$DS_STDERR" "hook says no"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: component example-app hook app-fails failed (exit 7)"
assert_eq "$(cut -d' ' -f1-2 "$order")" "term install
app install
term migrate"

# A store path in the mirror needs a generation.
manifest_edit '.hooks.agents_migrate |= map(select(.name != "app-fails"))
  | .hooks.agents_post += [{component: "example-app", name: "stored", phase: "main", profiles: null,
      script: "<store>/example-app-stored.sh"}]'
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "component example-app hook stored: <store>/example-app-stored.sh is a Nix store path the manifest mirror does not carry; pass --generation with a built generation"
