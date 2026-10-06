# Instance Home Manager module: personal settings that belong to no
# component. lib.mkInstance appends it after the enabled components, so it
# can set any Home Manager option and refine what a component sets.
#
# Besides the Home Manager arguments (config, lib, pkgs, ...), every module
# receives: profile (the profile being built), username and homeDirectory
# (the identity being built), packages (the instance package set), pins
# (versions.lock.json), inputs (the flake inputs) and dotsteward (cfg, the
# resolved workstation.toml, and root, the instance source).
{ ... }:
{
  # Examples; uncomment one and add the arguments it uses (pkgs, lib,
  # profile) to the set above.
  #
  # Packages from the locked nixpkgs:
  #   home.packages = [ pkgs.jq ];
  #
  # Starship settings, with the shell component enabled:
  #   programs.starship.settings.add_newline = false;
  #
  # An environment variable for every profile:
  #   home.sessionVariables.EXAMPLE_SETTING = "value";
  #
  # A file in one profile only:
  #   home.file.".config/example/notes.txt" = lib.mkIf (profile == "workstation") {
  #     text = "Only on the workstation profile.\n";
  #   };
}
