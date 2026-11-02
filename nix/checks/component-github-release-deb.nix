# The catalog components that install a vendor DEB published as a GitHub
# release asset (modules/core/github-release-deb.nix: pdfcraft, gridcraft,
# wordcraft, deckcraft, craft-anything; tests/nix/components/github-release-deb):
# their contract values and pins declarations as lib.mkInstance evaluates
# them, the Linux-only platform and deb-only method guards, the seeds and
# the pins engine over them, the shared E2E hook over stand-ins of dpkg,
# APT and the CLI, and the docs. The tests evaluate instances with
# nix-instantiate against an isolated store, so the sandbox needs Nix and
# the nixpkgs and home-manager sources; a setup hook exports their paths.
{
  self,
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;

  testEnv = pkgs.writeTextFile {
    name = "dotsteward-component-github-release-deb-test-env";
    destination = "/nix-support/setup-hook";
    text = ''
      export DS_NIXPKGS=${pkgs.path}
      export DS_HOME_MANAGER=${self.inputs.home-manager}
    '';
  };
in
cli.mkTestCheck {
  name = "component-github-release-deb";
  paths = [ "tests/nix/components/github-release-deb" ];
  nativeBuildInputs = [
    pkgs.nix
    pkgs.shellcheck
    testEnv
  ];
  postCheck = ''
    shellcheck -x tests/nix/components/github-release-deb/*.sh modules/core/github-release-deb-e2e.sh
  '';
}
