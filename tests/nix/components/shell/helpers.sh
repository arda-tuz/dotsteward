# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # Nix expressions in single quotes
# Helpers for the shell component tests (tests/nix/components/shell).
#
# Builds on tests/nix/instance/helpers.sh: expressions are evaluated with the
# instance prelude in scope (instance, homeOf, storeless, nixpkgsInput, ...)
# against an isolated Nix store. The fixture instance enables the catalog
# component shell of the checkout under test.
#
#   shell_fixture             the fixture instance directory
#   shell_eval ROOT EXPR      EXPR as JSON with `i` bound to the instance at
#                             ROOT (a directory), `home` to the Home Manager
#                             config of its workstation profile on
#                             x86_64-linux and `pkgs` to the locked nixpkgs
#                             of x86_64-linux; fails the test on an error
#   shell_raw ROOT EXPR       the string value of EXPR without JSON quoting
#   shell_fails ROOT EXPR NEEDLE...
#                             evaluating EXPR fails with every NEEDLE
#   shell_substitute FILE     replaces @AUTOSUGGESTIONS@ and
#                             @SYNTAX_HIGHLIGHTING@ in FILE with the store
#                             paths of the locked zsh plugins

# shellcheck source=tests/nix/instance/helpers.sh
source "$DS_REPO_ROOT/tests/nix/instance/helpers.sh"

shell_fixture=$DS_REPO_ROOT/tests/nix/components/shell/fixtures/instance

_shell_scope() {
  printf '%s' "let
    i = instance { root = /. + \"$1\"; };
    home = homeOf i \"x86_64-linux\" \"workstation\";
    pkgs = import nixpkgsInput { system = \"x86_64-linux\"; };
  in ($2)"
}

shell_eval() {
  (($# == 2)) || ds_fail "shell_eval: usage: shell_eval ROOT EXPR"
  nix_instance_eval "$(_shell_scope "$1" "$2")" || ds_fail "evaluation failed: $2: $DS_STDERR"
  printf '%s\n' "$DS_STDOUT"
}

shell_raw() {
  shell_eval "$@" | jq -j .
}

shell_fails() {
  (($# >= 3)) || ds_fail "shell_fails: usage: shell_fails ROOT EXPR NEEDLE..."
  local root=$1 expr=$2 needle
  shift 2
  if nix_instance_eval "$(_shell_scope "$root" "$expr")"; then
    ds_fail "expected the evaluation to fail: $expr; got: $DS_STDOUT"
  fi
  for needle in "$@"; do
    assert_contains "$DS_STDERR" "$needle" "$expr"
  done
}

shell_substitute() {
  local paths autosuggestions highlighting
  paths=$(shell_eval "$shell_fixture" 'storeless [ "${pkgs.zsh-autosuggestions}" "${pkgs.zsh-syntax-highlighting}" ]')
  autosuggestions=$(jq -r '.[0]' <<<"$paths")
  highlighting=$(jq -r '.[1]' <<<"$paths")
  [[ $autosuggestions == /*-zsh-autosuggestions-* && $highlighting == /*-zsh-syntax-highlighting-* ]] ||
    ds_fail "unexpected plugin store paths: [$autosuggestions] [$highlighting]"
  sed -i -e "s|@AUTOSUGGESTIONS@|$autosuggestions|g" -e "s|@SYNTAX_HIGHLIGHTING@|$highlighting|g" "$1"
}
