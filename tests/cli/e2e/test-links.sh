# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# Managed links and agent-rule bytes (SPEC 8.3 step 4; R3): every managed
# link of the manifest is a symlink that resolves (core:managed-links), and
# every agent-rules target of a component active in the profile has the
# bytes of agent_rules.source (<component>:agent-rules); targets of
# components outside the profile are not checked. A <store>/ source of the
# manifest mirror needs --generation.
# shellcheck source=tests/cli/e2e/helpers.sh
source "$DS_REPO_ROOT/tests/cli/e2e/helpers.sh"

none='{"command": null, "versionArgv": null, "minimum": null}'
add_component example-app external "$none"
add_component example-term external "$none" '["fresh"]'
mkdir -p "$agents_inst/rules"
printf '# Agent rules\n\nBe precise.\n' >"$agents_inst/rules/AGENTS.md"
manifest_edit '.managed_links = ["~/.config/nix/nix.conf", "~/.zshrc"]
  | .agent_rules = {source: "<instance>/rules/AGENTS.md", targets: [
      {component: "example-app", path: ".example/AGENTS.md", force: false},
      {component: "example-term", path: ".term/AGENTS.md", force: false}]}'
publish_instance

# What Home Manager activation leaves behind: links into a store.
store=$DS_TEST_ROOT/hm-store
mkdir -p "$store" "$HOME/.config/nix" "$HOME/.example"
printf 'experimental-features = nix-command flakes\n' >"$store/nix.conf"
printf '# zshrc\n' >"$store/zshrc"
cp "$agents_inst/rules/AGENTS.md" "$store/AGENTS.md"
ln -s "$store/nix.conf" "$HOME/.config/nix/nix.conf"
ln -s "$store/zshrc" "$HOME/.zshrc"
ln -s "$store/AGENTS.md" "$HOME/.example/AGENTS.md"
assert_exit 0 run_e2e

# Managed links: missing, a regular file, dangling.
rm "$HOME/.zshrc"
assert_exit 1 run_e2e --json
assert_eq "$(jq -cn --arg home "$HOME" '[["core:managed-links", "managed-link-missing", ($home + "/.zshrc")]]')" \
  "$(findings)"
assert_contains "$DS_STDOUT" "managed link missing: $HOME/.zshrc"
printf '# local copy\n' >"$HOME/.zshrc"
assert_exit 1 run_e2e
assert_contains "$DS_STDERR" "not a Home Manager symlink: $HOME/.zshrc"
rm "$HOME/.zshrc"
ln -s "$store/gone" "$HOME/.zshrc"
assert_exit 1 run_e2e --json --keep-going
assert_eq "$(jq -cn --arg home "$HOME" '[["core:managed-links", "managed-link-broken", ($home + "/.zshrc")]]')" \
  "$(findings)"
assert_contains "$DS_STDOUT" "broken symlink: $HOME/.zshrc"
rm "$HOME/.zshrc"
ln -s "$store/zshrc" "$HOME/.zshrc"

# Agent rules: other bytes, then missing. The fresh-only target is never
# read in the workstation profile.
printf '# Agent rules\n\nBe vague.\n' >"$store/AGENTS.md"
assert_exit 1 run_e2e --json
assert_eq "$(jq -cn --arg home "$HOME" '[["example-app:agent-rules", "agent-rules-mismatch", ($home + "/.example/AGENTS.md")]]')" \
  "$(findings)"
assert_contains "$DS_STDOUT" "agent rules differ from $agents_inst/rules/AGENTS.md: $HOME/.example/AGENTS.md"
cp "$agents_inst/rules/AGENTS.md" "$store/AGENTS.md"
rm "$HOME/.example/AGENTS.md"
assert_exit 1 run_e2e
assert_contains "$DS_STDERR" "agent rules missing: $HOME/.example/AGENTS.md"
ln -s "$store/AGENTS.md" "$HOME/.example/AGENTS.md"
assert_exit 0 run_e2e
assert_exit 1 run_e2e --profile fresh --json --keep-going
assert_eq "$(jq -cn --arg home "$HOME" '[["example-term:agent-rules", "agent-rules-missing", ($home + "/.term/AGENTS.md")]]')" \
  "$(findings)"

# A source the mirror cannot resolve, then the same source in a built
# generation's manifest.
manifest_edit '.agent_rules.source = "<store>/AGENTS.md"'
publish_instance
assert_exit 1 run_e2e --json
assert_eq '[["example-app:agent-rules","source-unresolvable","<store>/AGENTS.md"]]' "$(findings)"
assert_contains "$DS_STDOUT" "<store>/AGENTS.md is a Nix store path the manifest mirror does not carry; pass --generation with a built generation"
make_generation
jq --arg source "$store/AGENTS.md" '.agent_rules.source = $source' "$agents_manifest" \
  >"$agents_gen/home-path/share/dotsteward/manifest.json"
assert_exit 0 run_e2e --generation "$agents_gen"
assert_eq "" "$(temp_dirs)"
