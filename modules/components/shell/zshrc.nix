# The default ~/.zshrc blocks of the shell component (3.6) and the options
# that shape them ([components.shell].options of workstation.toml):
#
#   autosuggestions      bool, default true: source zsh-autosuggestions
#   syntaxHighlighting   bool, default true: source zsh-syntax-highlighting
#
# Blocks, in order: 10 compinit, 20 history, 30 local-bin-path, 40 plugins
# (absent when both plugins are off), 70 nix-profile-path, 99 starship-init.
# Core renders them (modules/core/zshrc.nix); an instance adds its own blocks
# between them by order, and replaces a default block's text with an
# ordinary definition (the texts here have default priority). The plugins
# are sourced from the store paths of the locked nixpkgs.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  where = "dotsteward: [components.shell].options";

  defaults = {
    autosuggestions = true;
    syntaxHighlighting = true;
  };
  known = lib.attrNames defaults;

  given = config.dotsteward.components.shell.options;

  unknown = lib.filter (name: !(lib.elem name known)) (lib.attrNames given);

  invalid = name: "${where}.${name} must be a boolean, got ${builtins.toJSON given.${name}}";

  problems =
    map (name: "${where}: unknown option ${name} (known: ${lib.concatStringsSep ", " known})") unknown
    ++ map invalid (lib.filter (name: given ? ${name} && !builtins.isBool given.${name}) known);

  # The value of a known option; a non-boolean fails wherever it is read
  # (the assertions report every problem at once).
  option =
    name:
    let
      value = given.${name} or defaults.${name};
    in
    if builtins.isBool value then value else throw (invalid name);

  autosuggestions = option "autosuggestions";
  syntaxHighlighting = option "syntaxHighlighting";

  block = order: text: {
    inherit order;
    text = lib.mkDefault text;
  };
in
{
  assertions = map (message: {
    assertion = false;
    inherit message;
  }) problems;

  dotsteward.shell.zshrc.blocks = {
    compinit = block 10 ''
      autoload -Uz compinit && compinit
    '';

    history = block 20 ''
      HISTFILE="$HOME/.zsh_history"
      HISTSIZE=10000
      SAVEHIST=10000
      setopt APPEND_HISTORY HIST_IGNORE_DUPS SHARE_HISTORY
    '';

    local-bin-path = block 30 ''
      typeset -U path PATH
      path=("$HOME/.local/bin" $path)
      export PATH
    '';

    plugins = lib.mkIf (autosuggestions || syntaxHighlighting) (
      block 40 (
        lib.optionalString autosuggestions ''
          source ${pkgs.zsh-autosuggestions}/share/zsh-autosuggestions/zsh-autosuggestions.zsh
        ''
        + lib.optionalString syntaxHighlighting ''
          source ${pkgs.zsh-syntax-highlighting}/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
        ''
      )
    );

    nix-profile-path = block 70 ''
      if [[ -d "$HOME/.nix-profile/bin" ]]; then
        path=("$HOME/.nix-profile/bin" $path)
      fi
    '';

    starship-init = block 99 ''
      if [[ $TERM != dumb ]]; then
        eval "$(starship init zsh)"
      fi
    '';
  };
}
