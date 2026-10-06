# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # Nix expressions in single quotes
# The shell component's .zshrc (3.6): the default blocks reproduce the
# reference layout byte for byte, instance blocks slot in by order, and the
# plugins block follows the autosuggestions and syntaxHighlighting options.
# shellcheck source=tests/nix/components/shell/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/shell/helpers.sh"

fixtures=$DS_REPO_ROOT/tests/nix/components/shell/fixtures

# assert_zshrc ROOT EXPECTED_FILE MESSAGE: the rendered text and the linked
# ~/.zshrc of ROOT's workstation profile equal EXPECTED_FILE (placeholders
# substituted) byte for byte.
assert_zshrc() {
  local root=$1 expected=$DS_TEST_ROOT/expected.zshrc rendered
  cp "$2" "$expected"
  shell_substitute "$expected"
  rendered=$(shell_eval "$root" 'storeless {
    text = home.dotsteward.shell.zshrc.text;
    file = home.home.file.".zshrc".text;
  }')
  jq -j .text <<<"$rendered" >"$DS_TEST_ROOT/text.zshrc"
  jq -j .file <<<"$rendered" >"$DS_TEST_ROOT/file.zshrc"
  if ! cmp -s "$expected" "$DS_TEST_ROOT/text.zshrc"; then
    ds_fail "$3: rendered .zshrc differs: $(diff "$expected" "$DS_TEST_ROOT/text.zshrc" || true)"
  fi
  cmp -s "$DS_TEST_ROOT/text.zshrc" "$DS_TEST_ROOT/file.zshrc" ||
    ds_fail "$3: ~/.zshrc is not dotsteward.shell.zshrc.text"
}

# Instance blocks (45 attached to the plugins block, 50, 80) around the
# component defaults.
assert_zshrc "$shell_fixture" "$fixtures/instance.zshrc" "instance blocks"

# The component defaults alone, in order 10 20 30 40 70 99.
bare=$(instance_copy "$shell_fixture")
rm "$bare/home.nix"
assert_zshrc "$bare" "$fixtures/defaults.zshrc" "defaults"
assert_eq '{"compinit":10,"history":20,"local-bin-path":30,"nix-profile-path":70,"plugins":40,"starship-init":99}' \
  "$(shell_eval "$bare" 'lib.mapAttrs (_: block: block.order) home.dotsteward.shell.zshrc.blocks' | jq -cS .)" \
  "default block names and orders"

# set_options ROOT TOML: replaces [components.shell] options of ROOT.
set_options() {
  sed -i '/^options = /d' "$1/workstation.toml"
  printf 'options = %s\n' "$2" >>"$1/workstation.toml"
}

# One plugin off: its line disappears; both off: the block disappears.
copy=$(instance_copy "$bare")
set_options "$copy" '{ autosuggestions = false }'
sed '/@AUTOSUGGESTIONS@/d' "$fixtures/defaults.zshrc" >"$DS_TEST_ROOT/no-autosuggestions.zshrc"
assert_zshrc "$copy" "$DS_TEST_ROOT/no-autosuggestions.zshrc" "autosuggestions off"

set_options "$copy" '{ syntaxHighlighting = false }'
sed '/@SYNTAX_HIGHLIGHTING@/d' "$fixtures/defaults.zshrc" >"$DS_TEST_ROOT/no-highlighting.zshrc"
assert_zshrc "$copy" "$DS_TEST_ROOT/no-highlighting.zshrc" "syntaxHighlighting off"

set_options "$copy" '{ autosuggestions = false, syntaxHighlighting = false }'
sed '/^source @/d' "$fixtures/defaults.zshrc" | cat -s >"$DS_TEST_ROOT/no-plugins.zshrc"
assert_zshrc "$copy" "$DS_TEST_ROOT/no-plugins.zshrc" "both plugins off"
assert_eq 'false' "$(shell_eval "$copy" 'home.dotsteward.shell.zshrc.blocks ? plugins')" "no plugins block"

set_options "$copy" '{ autosuggestions = true, syntaxHighlighting = true }'
assert_zshrc "$copy" "$fixtures/defaults.zshrc" "both plugins on explicitly"

# An instance replaces a default block's text with an ordinary definition
# (the defaults have default priority) and keeps its position.
override=$(instance_copy "$bare")
cat >"$override/home.nix" <<'NIX'
{
  dotsteward.shell.zshrc.blocks.history.text = ''
    HISTFILE="$HOME/.zsh_history"
  '';
}
NIX
awk 'NR == 3 { print; next } NR >= 4 && NR <= 6 { next } { print }' "$fixtures/defaults.zshrc" >"$DS_TEST_ROOT/override.zshrc"
assert_zshrc "$override" "$DS_TEST_ROOT/override.zshrc" "overridden default block"

# Invalid options fail the configuration with the option named.
set_options "$copy" '{ autosuggestion = false }'
shell_fails "$copy" 'home.home.activationPackage.drvPath' \
  "dotsteward: [components.shell].options: unknown option autosuggestion (known: autosuggestions, syntaxHighlighting)"
set_options "$copy" '{ syntaxHighlighting = "yes" }'
shell_fails "$copy" 'home.home.activationPackage.drvPath' \
  'dotsteward: [components.shell].options.syntaxHighlighting must be a boolean, got "yes"'
