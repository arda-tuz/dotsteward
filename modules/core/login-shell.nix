# The login shell path consumed by rebuild, bootstrap and e2e.
{
  config,
  lib,
  ...
}:
let
  shell = config.dotsteward.components.shell or null;
in
{
  options.dotsteward.loginShell.path = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = if shell != null && shell.enable then "$HOME/.nix-profile/bin/zsh" else null;
    defaultText = lib.literalMD ''`"$HOME/.nix-profile/bin/zsh"` when the shell component is enabled, else null'';
    description = ''
      Login shell to set, as written to the shells file and the user database
      ($HOME is expanded at run time); null leaves the login shell alone.
    '';
  };
}
