# The always-on Home Manager modules of dotsteward (homeModules.core).
#
# mkInstance evaluates them with these special arguments:
#   profile, username, homeDirectory   what mkHome was called with
#   packages                           the instance package set (the CLI is
#                                      packages.dotsteward)
#   pins, inputs                       versions.lock.json and the instance
#                                      flake inputs
#   dotsteward = { cfg, root, system, lib }
#                                      the resolved workstation.toml, the
#                                      instance source, the system and the
#                                      dotsteward library
#
# Contract options (dotsteward.*) never depend on the profile; only
# home.packages and home.file content does, through each component's
# profiles field.
{
  imports = [
    ./identity.nix
    ./nix-conf.nix
    ./components.nix
    ./agent-rules.nix
    ./skills.nix
    ./cli.nix
    ./files.nix
    ./login-shell.nix
    ./zshrc.nix
    ./manifest.nix
  ];
}
