# shellcheck shell=bash
# shellcheck disable=SC2016,SC2088 # literal '~/' paths and shell snippets in single quotes
# The claude-code documentation: README.md records the
# verification of the self-update switch ("verified on <date> from
# <source>" or "not verified") with the decision that follows from it, and
# documents every method, platform and settings target; maintenance.md says
# how both pins are refreshed. Fenced shell blocks name only allowed
# commands (the command-names check of `dotsteward static`).
# shellcheck source=tests/nix/components/claude-code/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/claude-code/helpers.sh"

readme=$cc_component_dir/README.md
maintenance=$cc_component_dir/maintenance.md
[[ -f $readme ]] || ds_fail "missing $readme"
[[ -f $maintenance ]] || ds_fail "missing $maintenance"
readme_text=$(<"$readme")
maintenance_text=$(<"$maintenance")

# The verification record of the component README.
grep -qiE 'verified|not verified' "$readme" || ds_fail "README.md lacks the verification status"
grep -qE 'Verified on [0-9]{4}-[0-9]{2}-[0-9]{2} from ' "$readme" ||
  ds_fail "README.md lacks \"Verified on <date> from <source>\""
for needle in \
  "https://code.claude.com/docs/en/setup" \
  "https://code.claude.com/docs/en/env-vars" \
  DISABLE_AUTOUPDATER DISABLE_UPDATES \
  'policy = "at-least"' native_application_updates \
  "~/.local/share/claude/versions"; do
  assert_contains "$readme_text" "$needle" "README.md"
done

# Methods, platforms, pins and settings targets.
for needle in official-binary deb external linux-x64 darwin-arm64 \
  agent_tools.claude-code desktop_packages.claude-code \
  claude-settings claude-global "~/.claude/settings.json" "~/.claude.json" \
  "~/.claude/CLAUDE.md" "~/.claude/skills" "~/.local/bin/claude" \
  method_by_platform; do
  assert_contains "$readme_text" "$needle" "README.md"
done

# Refreshing the pins.
for needle in \
  "https://downloads.claude.ai/claude-code-releases/stable" \
  "manifest.json" \
  "https://downloads.claude.ai/claude-code/apt/stable" \
  holdback_reason agent_tools.claude-code desktop_packages.claude-code seed.json; do
  assert_contains "$maintenance_text" "$needle" "maintenance.md"
done

# Command names in the shell blocks of both files.
fw=$DS_TEST_ROOT/fw
mkdir -p "$fw/modules/components" "$fw/tests"
for entry in VERSION cli schema privacy; do
  cp -R "$DS_REPO_ROOT/$entry" "$fw/"
done
cp -R "$DS_REPO_ROOT/tests/static" "$fw/tests/"
cp -R "$cc_component_dir" "$fw/modules/components/"
chmod -R u+w "$fw"
assert_exit 0 bash -c 'cd "$1" && ./cli/dotsteward static --sandbox --only command-names' _ "$fw"
