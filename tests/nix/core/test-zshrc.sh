# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # Nix expressions and expected shell text in single quotes
# modules/core .zshrc blocks (3.6): ordered blocks rendered byte-exactly
# into dotsteward.shell.zshrc.text.
# shellcheck source=tests/nix/core/helpers.sh
source "$DS_REPO_ROOT/tests/nix/core/helpers.sh"

# render BLOCKS: the rendered text for a Nix attribute set of blocks.
render() {
  core_json "(homeOf { modules = [ { dotsteward.shell.zshrc.blocks = $1; } ]; }).dotsteward.shell.zshrc.text"
}

# No blocks: empty text; core never writes ~/.zshrc itself.
assert_core_eq '""' '(homeOf { }).dotsteward.shell.zshrc.text'
assert_core_eq 'false' '(homeOf { modules = [ { dotsteward.shell.zshrc.blocks.one = { order = 10; text = "one\n"; }; } ]; }).home.file ? ".zshrc"'

# Sorted by order (not by name), joined with one blank line.
assert_eq '"a\n\nb\n\nc\n"' "$(render '{ z = { order = 10; text = "a\n"; }; y = { order = 20; text = "b\n"; }; x = { order = 30; text = "c\n"; }; }')" \
  "order"

# attachToPrevious joins without the blank line, also as the first block.
assert_eq '"a\nb\n\nc\n"' "$(render '{ one = { order = 10; text = "a\n"; }; two = { order = 20; text = "b\n"; attachToPrevious = true; }; three = { order = 30; text = "c\n"; }; }')" \
  "attachToPrevious"
assert_eq '"a\n\nb\n"' "$(render '{ one = { order = 10; text = "a\n"; attachToPrevious = true; }; two = { order = 20; text = "b\n"; }; }')" \
  "attachToPrevious on the first block"

# Equal orders are ordered by name.
assert_eq '"a\n\nb\n"' "$(render '{ beta = { order = 50; text = "b\n"; }; alpha = { order = 50; text = "a\n"; }; }')" \
  "ties by name"

# Several modules contribute blocks; a block's text must end with a newline.
assert_core_eq '"a\n\nb\n"' '(homeOf { modules = [ { dotsteward.shell.zshrc.blocks.two = { order = 20; text = "b\n"; }; } { dotsteward.shell.zshrc.blocks.one = { order = 10; text = "a\n"; }; } ]; }).dotsteward.shell.zshrc.text'
assert_core_fails '(homeOf { modules = [ { dotsteward.shell.zshrc.blocks.bad = { order = 10; text = "no newline"; }; } ]; }).dotsteward.shell.zshrc.text' \
  "dotsteward: .zshrc block bad must end with a newline"
assert_core_fails '(homeOf { modules = [ { dotsteward.shell.zshrc.text = "x\n"; } ]; }).dotsteward.shell.zshrc.text' \
  "dotsteward.shell.zshrc.text" "read-only"

# Byte fidelity with multi-line blocks written as Nix indented strings, the
# way components declare them: the rendered file equals the expected bytes.
expected=$DS_TEST_ROOT/expected.zshrc
cat >"$expected" <<'EOF'
autoload -Uz compinit && compinit

HISTFILE="$HOME/.zsh_history"
HISTSIZE=10000
SAVEHIST=10000
setopt APPEND_HISTORY HIST_IGNORE_DUPS SHARE_HISTORY

typeset -U path PATH
path=("$HOME/.local/bin" $path)
export PATH
bindkey -e

if [[ -d "$HOME/.nix-profile/bin" ]]; then
  path=("$HOME/.nix-profile/bin" $path)
fi

if [[ $TERM != dumb ]]; then
  eval "$(starship init zsh)"
fi
EOF
blocks=$(
  cat <<'EOF'
{
  compinit = { order = 10; text = "autoload -Uz compinit && compinit\n"; };
  history = {
    order = 20;
    text = ''
      HISTFILE="$HOME/.zsh_history"
      HISTSIZE=10000
      SAVEHIST=10000
      setopt APPEND_HISTORY HIST_IGNORE_DUPS SHARE_HISTORY
    '';
  };
  local-bin-path = {
    order = 30;
    text = ''
      typeset -U path PATH
      path=("$HOME/.local/bin" $path)
      export PATH
    '';
  };
  keybindings = { order = 45; text = "bindkey -e\n"; attachToPrevious = true; };
  nix-profile-path = {
    order = 70;
    text = ''
      if [[ -d "$HOME/.nix-profile/bin" ]]; then
        path=("$HOME/.nix-profile/bin" $path)
      fi
    '';
  };
  starship-init = {
    order = 99;
    text = ''
      if [[ $TERM != dumb ]]; then
        eval "$(starship init zsh)"
      fi
    '';
  };
}
EOF
)
render "$blocks" | jq -j . >"$DS_TEST_ROOT/actual.zshrc"
assert_eq "$(sha256sum <"$expected")" "$(sha256sum <"$DS_TEST_ROOT/actual.zshrc")" ".zshrc bytes"
