# lib.mkInstance (tests/nix/instance, top-level files): outputs, the package
# fixpoint, pinned versions, component wiring, the manifest, mirrors and
# stage-0 rendering, evaluated with nix-instantiate against an isolated
# store. In addition, the fixture instances are evaluated inside this flake
# (string roots, the framework's own inputs) and their checks are built:
# Home Manager activation packages, the package check, instance-static and
# manifest-consistent, so the outputs are proven buildable, not only
# evaluable.
{
  self,
  pkgs,
  lib,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;

  jsonschemaPython = pkgs.python3.withPackages (ps: [ ps.jsonschema ]);

  testEnv = pkgs.writeTextFile {
    name = "dotsteward-nix-instance-test-env";
    destination = "/nix-support/setup-hook";
    text = ''
      export DS_NIXPKGS=${pkgs.path}
      export DS_HOME_MANAGER=${self.inputs.home-manager}
      export DS_JSONSCHEMA_PYTHON=${jsonschemaPython.interpreter}
    '';
  };

  # The top-level test files; assertions/ and consistency/ belong to
  # checks.nix-assertions and checks.manifest-consistent.
  testDir = ../../tests/nix/instance;
  testFiles = lib.sort lib.lessThan (
    lib.attrNames (
      lib.filterAttrs (
        name: type: type == "regular" && lib.hasPrefix "test-" name && lib.hasSuffix ".sh" name
      ) (builtins.readDir testDir)
    )
  );

  fixtures = import ../../tests/nix/instance/flake-instances.nix { inherit self dsLib lib; };
  inherit (fixtures) minimal example;

  linux = example.checks.x86_64-linux;
in
cli.mkTestCheck {
  name = "nix-instance";
  paths = map (file: "tests/nix/instance/${file}") testFiles;
  nativeBuildInputs = [
    pkgs.nix
    testEnv
  ];
  postCheck = ''
    fail() {
      printf 'nix-instance: %s\n' "$*" >&2
      exit 1
    }
    # Built outputs of the fixture instances.
    for check in ${minimal.checks.x86_64-linux.home} ${linux.home} ${linux.home-fresh} ${linux.fresh-home}; do
      [[ -x $check/activate ]] || fail "$check is not an activation package"
    done
    home=${linux.home}/home-files
    [[ $(<"$home/.example-home") == "from home.nix" ]] || fail ".example-home"
    [[ $(<"$home/.example-term/greeting") == "hello from options" ]] || fail ".example-term/greeting"
    cmp ${linux.home}/home-path/share/dotsteward/manifest.json \
      ${pkgs.writeText "manifest.json" (builtins.toJSON example.dotstewardManifest.x86_64-linux)} ||
      fail "the generation manifest differs from dotstewardManifest"
    [[ $(${linux.example-app}/bin/example-app) == "example-app 1.2.3" ]] || fail "example-app"
    [[ $(${example.packages.x86_64-linux.example-term}/bin/example-term) == "example-app 1.2.3" ]] ||
      fail "example-term"
    [[ -x ${example.packages.x86_64-linux.local-maintained-files}/bin/local-maintained-files ]] ||
      fail "local-maintained-files"
    [[ -e ${linux.instance-static} && -e ${linux.manifest-consistent} ]] || fail "instance checks"
    [[ -e ${minimal.checks.x86_64-linux.instance-static} ]] || fail "minimal instance-static"
  '';
}
