# XDG directories and the user's nix.conf (flakes enabled, no dirty-tree
# warning).
{
  xdg = {
    enable = true;
    configFile."nix/nix.conf".text = ''
      experimental-features = nix-command flakes
      warn-dirty = false
    '';
  };

  dotsteward.core = {
    managedLinks = [ "~/.config/nix/nix.conf" ];
    backupPaths = [ "~/.config/nix/nix.conf" ];
  };
}
