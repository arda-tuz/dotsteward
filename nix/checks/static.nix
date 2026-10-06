# Framework static contracts (tests/static): the command-name rule, component
# seeds, pin literals, the instance contracts (T1-T3) and the instance
# privacy policy. The seed lock-path test evaluates the catalog's Home
# Manager configurations with nix-instantiate against an isolated store, so
# the sandbox needs Nix and the nixpkgs and home-manager sources; a setup
# hook exports their paths. Then `dotsteward static --sandbox` over the
# framework source itself, which in the sandbox has no .git and is listed
# with find, and the packaged CLI on a small instance, which proves the package carries
# the template copies and schemas the instance checks compare with.
{
  self,
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;

  testEnv = pkgs.writeTextFile {
    name = "dotsteward-static-test-env";
    destination = "/nix-support/setup-hook";
    text = ''
      export DS_NIXPKGS=${pkgs.path}
      export DS_HOME_MANAGER=${self.inputs.home-manager}
    '';
  };
in
cli.mkTestCheck {
  name = "static";
  paths = [ "tests/static" ];
  nativeBuildInputs = [
    pkgs.shellcheck
    pkgs.gnutar
    pkgs.nix
    testEnv
  ];
  postCheck = ''
    ./cli/dotsteward static --sandbox

    instance=$(mktemp -d)
    mkdir -p "$instance/.dotsteward"
    cp template/.dotsteward/cli.sh "$instance/.dotsteward/cli.sh"
    if [[ -f template/bootstrap.sh ]]; then
      cp template/bootstrap.sh "$instance/bootstrap.sh"
    fi
    cat >"$instance/workstation.toml" <<'TOML'
    schema_version = 1

    [identity]
    username = "example"

    [instance]
    remote = "git@github.com:example/workstation.git"

    [nix]
    state_version = "26.05"

    [profiles]
    names = ["main"]
    TOML
    HOME=$(mktemp -d) ${pkgs.lib.getExe cli} --instance "$instance" static --sandbox \
      --only launcher,bootstrap,overlays,allowlist,protected
  '';
}
