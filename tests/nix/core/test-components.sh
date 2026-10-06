# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # Nix expressions and expected shell text in single quotes
# modules/core components: the contract option, the nix method, the active
# set (enable, profiles, platforms), managed links and the login shell path.
# shellcheck source=tests/nix/core/helpers.sh
source "$DS_REPO_ROOT/tests/nix/core/helpers.sh"

# The contract option is declared by core.
assert_core_eq '{}' '(homeOf { }).dotsteward.components'
assert_core_eq '"nix"' '(homeOf { modules = componentModules; }).dotsteward.components.example-app.method'

# example_names ARGS: which synthetic component packages Home Manager installs.
example_names() {
  core_json "lib.sort lib.lessThan (lib.filter (n: lib.hasPrefix \"example-\" n) (packageNames (homeOf ($1))))" | jq -c .
}

# Disabled components contribute nothing.
assert_eq '[]' "$(example_names '{ modules = componentModules; }')" "disabled components"

# Only components whose resolved method is nix get home.packages; the
# install.nix block of an official-binary component is not used.
assert_eq '["example-app"]' "$(example_names '{ config = "workstation"; modules = componentModules; }')" "nix method only"

# Profile scoping: example-term is limited to the workstation profile.
switch_term='{ dotsteward.components.example-term.method = lib.mkForce "nix"; }'
assert_eq '["example-app","example-term"]' \
  "$(example_names "{ config = \"workstation\"; modules = componentModules ++ [ $switch_term ]; }")" "active profile"
assert_eq '["example-app"]' \
  "$(example_names "{ config = \"workstation\"; profile = \"fresh\"; modules = componentModules ++ [ $switch_term ]; }")" \
  "inactive profile"

# Platform scoping: a component limited to darwin is not installed on Linux.
darwin_app='{ dotsteward.components.example-app.platforms = [ "darwin" ]; }'
assert_eq '[]' "$(example_names "{ config = \"workstation\"; modules = componentModules ++ [ $darwin_app ]; }")" \
  "unsupported platform"
assert_eq '["example-app"]' \
  "$(example_names "{ config = \"workstation\"; system = \"aarch64-darwin\"; homeDirectory = \"/Users/alice\"; modules = componentModules ++ [ $darwin_app ]; }")" \
  "supported platform"

# Managed links: core first, then the enabled components in [components]
# order; the same list in every profile (D20).
expected='["~/.config/nix/nix.conf","~/.example-term/RULES.md","~/.example-app/AGENTS.md"]'
assert_core_eq "$expected" '(homeOf { config = "workstation"; modules = componentModules; }).dotsteward.managedLinks'
assert_core_eq "$expected" '(homeOf { config = "workstation"; profile = "fresh"; modules = componentModules; }).dotsteward.managedLinks'
assert_core_eq '["~/.config/nix/nix.conf"]' '(homeOf { modules = componentModules; }).dotsteward.managedLinks'

# An instance module adds its own managed links.
assert_core_eq '["~/.codex/skills/example-skill","~/.config/nix/nix.conf","~/.example-app/AGENTS.md","~/.example-term/RULES.md"]' \
  'lib.sort lib.lessThan (homeOf { config = "workstation"; modules = componentModules ++ [ { dotsteward.managedLinks = [ "~/.codex/skills/example-skill" ]; } ]; }).dotsteward.managedLinks'
assert_core_fails '(homeOf { modules = [ { dotsteward.managedLinks = [ "relative/link" ]; } ]; }).dotsteward.managedLinks' \
  "dotsteward.managedLinks"

# Login shell: the Nix profile zsh when shell is enabled, else null.
assert_core_eq '"$HOME/.nix-profile/bin/zsh"' '(homeOf { config = "workstation"; modules = componentModules; }).dotsteward.loginShell.path'
assert_core_eq '"$HOME/.nix-profile/bin/zsh"' '(homeOf { config = "workstation"; profile = "fresh"; modules = componentModules; }).dotsteward.loginShell.path'
assert_core_eq 'null' '(homeOf { modules = componentModules; }).dotsteward.loginShell.path'
assert_core_eq 'null' '(homeOf { }).dotsteward.loginShell.path'
assert_core_eq '"/usr/local/bin/zsh"' '(homeOf { modules = [ { dotsteward.loginShell.path = "/usr/local/bin/zsh"; } ]; }).dotsteward.loginShell.path'
