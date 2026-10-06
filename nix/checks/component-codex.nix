# The codex catalog component (tests/nix/components/codex): its contract
# values as lib.mkInstance evaluates them on both systems, the seed, the
# official-binary and external methods and the plugins hook end to end
# through the CLI against the stubs; then shellcheck over the hook and the
# tests. The tests evaluate instances with nix-instantiate against an
# isolated store, so the sandbox needs Nix itself and the nixpkgs and
# home-manager sources; a setup hook exports their paths.
{
  self,
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;

  testEnv = pkgs.writeTextFile {
    name = "dotsteward-component-codex-test-env";
    destination = "/nix-support/setup-hook";
    text = ''
      export DS_NIXPKGS=${pkgs.path}
      export DS_HOME_MANAGER=${self.inputs.home-manager}
    '';
  };
in
cli.mkTestCheck {
  name = "component-codex";
  paths = [ "tests/nix/components/codex" ];
  nativeBuildInputs = [
    pkgs.nix
    pkgs.shellcheck
    testEnv
  ];
  postCheck = ''
    shellcheck -x modules/components/codex/plugins.sh tests/nix/components/codex/*.sh
  '';
}
