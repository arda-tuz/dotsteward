# The opencode-pi catalog component (tests/nix/components/opencode-pi): its
# contract values on both systems, the Pi package (the derivation evaluated
# on x86_64-linux and aarch64-darwin, added to home.packages wherever the
# component is active), the seed and the README verification record, and
# the agents checks (Pi probes, OpenCode /skill API, Pi RPC) end to end
# through the CLI against the stubs; then shellcheck over the hooks and the
# tests. The tests evaluate Home Manager configurations and instances with
# nix-instantiate against an isolated store, so the sandbox needs Nix itself
# and the nixpkgs and home-manager sources; a setup hook exports their
# paths. Building the Pi package itself is checks.<system>.pi of every
# instance that enables the component (package.nix sets check = true).
{
  self,
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;

  testEnv = pkgs.writeTextFile {
    name = "dotsteward-component-opencode-pi-test-env";
    destination = "/nix-support/setup-hook";
    text = ''
      export DS_NIXPKGS=${pkgs.path}
      export DS_HOME_MANAGER=${self.inputs.home-manager}
    '';
  };
in
cli.mkTestCheck {
  name = "component-opencode-pi";
  paths = [ "tests/nix/components/opencode-pi" ];
  nativeBuildInputs = [
    pkgs.nix
    pkgs.shellcheck
    testEnv
  ];
  postCheck = ''
    shellcheck -x modules/components/opencode-pi/probes/*.sh tests/nix/components/opencode-pi/*.sh
  '';
}
