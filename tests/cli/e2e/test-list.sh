# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # literal $HOME in the manifest on purpose
# `dotsteward e2e --list`: the check ids of a profile in run
# order, without running anything: no hook, no remote, no file read in HOME.
# Ids are <component>:<check-name> for component checks and hooks and
# core:<check-name> for the runner's own checks; checks with nothing to
# verify are not listed (no commands, no managed links, no agent rules
# source, no files, no settings buffer, no login shell), and
# --skip-repo-checks drops the repository checks. --list --json prints
# { "profile", "checks": [ ids ] }.
# shellcheck source=tests/cli/e2e/helpers.sh
source "$DS_REPO_ROOT/tests/cli/e2e/helpers.sh"

# The empty instance.
assert_exit 0 run_e2e --list
assert_eq "core:agents
core:repo-clean
core:repo-origin
core:repo-remote
core:repo-skill-count
core:framework-skills" "$DS_STDOUT"
assert_exit 0 run_e2e --list --skip-repo-checks
assert_eq "core:agents
core:framework-skills" "$DS_STDOUT"

# Every kind of check, two components (example-term before example-app in
# the component order) and profile-scoped hooks.
none='{"command": null, "versionArgv": null, "minimum": null}'
add_component example-term external "$none"
add_component example-app external "$none"
add_component gamma external "$none" '["fresh"]'
manifest_edit '.checks.commands = [{component: "core", command: "jq"}, {component: "example-app", command: "example-app"}]
  | .managed_links = ["~/.config/nix/nix.conf"]
  | .agent_rules = {source: "<instance>/rules/AGENTS.md", targets: [
      {component: "example-app", path: ".example/AGENTS.md", force: false},
      {component: "example-term", path: ".term/AGENTS.md", force: true},
      {component: "example-term", path: ".term/rules.md", force: false},
      {component: "gamma", path: ".gamma/AGENTS.md", force: false}]}
  | .files = {"example-conf": {source: "<instance>/files/example.conf", target: "~/.config/example/app.conf",
      mode: "0644", policy: "always"}}
  | .login_shell = "$HOME/.nix-profile/bin/zsh"'
for phase in late main early; do
  hook_log_script "app-$phase" | add_e2e_hook example-app "app-$phase" "$phase"
  hook_log_script "term-$phase" | add_e2e_hook example-term "term-$phase" "$phase"
done
hook_log_script fresh-only | add_e2e_hook example-app fresh-only late '["fresh"]'
hook_log_script gamma-check | add_e2e_hook gamma gamma-check main
write_buffer <<'TOML'
schema_version = 1
TOML
publish_instance
: >"$DS_FAKESSH_LOG"
before=$(home_state)

assert_exit 0 run_e2e --list
assert_eq "core:commands
example-term:term-early
example-app:app-early
core:managed-links
example-term:agent-rules
example-app:agent-rules
core:files
core:agents
core:settings-files
core:settings-verify
example-term:term-main
example-app:app-main
core:login-shell
core:repo-clean
core:repo-origin
core:repo-remote
core:repo-skill-count
example-term:term-late
example-app:app-late
core:framework-skills" "$DS_STDOUT"
assert_eq "" "$DS_STDERR"

assert_exit 0 run_e2e --list --profile fresh --skip-repo-checks
assert_eq "core:commands
example-term:term-early
example-app:app-early
core:managed-links
example-term:agent-rules
example-app:agent-rules
gamma:agent-rules
core:files
core:agents
core:settings-files
core:settings-verify
example-term:term-main
example-app:app-main
gamma:gamma-check
core:login-shell
example-term:term-late
example-app:app-late
example-app:fresh-only
core:framework-skills" "$DS_STDOUT"

assert_exit 0 run_e2e --list --json --skip-repo-checks
assert_json - '.profile == "workstation" and (.checks | length) == 16
  and .checks[0] == "core:commands" and .checks[-1] == "core:framework-skills"' <<<"$DS_STDOUT"

# Nothing ran: no hook, no remote, no change in HOME, no temporary
# directory left behind.
assert_eq "" "$(<"$e2e_hook_log")"
assert_eq "" "$(<"$DS_FAKESSH_LOG")"
assert_eq "$before" "$(home_state)"
assert_eq "" "$(temp_dirs)"
