# Nix library (tests/nix/lib): workstation.toml loading and validation, the
# component contract types, platform facts and pinAt. The tests evaluate the
# library with nix-instantiate against an isolated store, so the sandbox
# needs Nix itself, the nixpkgs source and a python with jsonschema for the
# independent schema validator; a setup hook exports their paths.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;

  jsonschemaPython = pkgs.python3.withPackages (ps: [ ps.jsonschema ]);

  testEnv = pkgs.writeTextFile {
    name = "dotsteward-nix-lib-test-env";
    destination = "/nix-support/setup-hook";
    text = ''
      export DS_NIXPKGS=${pkgs.path}
      export DS_JSONSCHEMA_PYTHON=${jsonschemaPython.interpreter}
    '';
  };
in
cli.mkTestCheck {
  name = "nix-lib";
  paths = [ "tests/nix/lib" ];
  nativeBuildInputs = [
    pkgs.nix
    testEnv
  ];
}
