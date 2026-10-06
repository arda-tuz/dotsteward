# Preflight, stage-0 and bootstrap stage 1 (tests/cli/bootstrap): the
# preflight command and its jq-free JSON, the generated
# template/bootstrap.sh against a synthetic instance with stubs (backups,
# snapshots, prerequisites, the verified Nix install, --install-nix-only,
# darwin), the stage-1 order and the generator. Stage-0 is the only pre-Nix
# script and must run with the macOS /bin/bash, GNU bash 3.2.57: the check
# builds it and hands it to the tests as DS_BASH32, so the stage-0 suites
# run under it as well as under the current bash. `file` gives the
# installer's MIME check a real answer. shellcheck covers the commands, the
# generator, the generated script and the tests.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;

  # GNU bash 3.2.57, the version macOS ships as /bin/bash. The 1990s C
  # needs a permissive dialect with today's compilers, and its parser is
  # regenerated with bison (the shipped y.tab.c predates the last patches
  # of parse.y).
  bash32 = pkgs.stdenv.mkDerivation {
    pname = "bash";
    version = "3.2.57";
    src = pkgs.fetchurl {
      urls = [
        "mirror://gnu/bash/bash-3.2.57.tar.gz"
        "https://ftp.gnu.org/gnu/bash/bash-3.2.57.tar.gz"
      ];
      hash = "sha256-P6na+F6/NQaPCQzlEoPd7rPHXrW8cLGkp8sFhov+BqQ=";
    };
    nativeBuildInputs = [ pkgs.bison ];
    env.NIX_CFLAGS_COMPILE = toString [
      "-std=gnu89"
      "-Wno-error=implicit-function-declaration"
      "-Wno-error=implicit-int"
      "-Wno-error=int-conversion"
      "-Wno-error=incompatible-pointer-types"
      "-Wno-error=return-mismatch"
    ];
    configureFlags = [
      "--without-bash-malloc"
      "--disable-nls"
    ];
    hardeningDisable = [ "format" ];
    enableParallelBuilding = false;
    doCheck = false;
    meta.platforms = pkgs.lib.platforms.linux;
  };

  # Exports DS_BASH32 for the test run (the harness keeps DS_* inputs).
  bash32Hook = pkgs.makeSetupHook { name = "dotsteward-bash32-hook"; } (
    pkgs.writeText "dotsteward-bash32-hook.sh" ''
      export DS_BASH32=${bash32}/bin/bash
    ''
  );
in
cli.mkTestCheck {
  name = "cli-bootstrap";
  paths = [ "tests/cli/bootstrap" ];
  nativeBuildInputs = [
    pkgs.shellcheck
    pkgs.file
    bash32Hook
  ];
  # The generator test compares the template byte for byte.
  keepShebangs = [ "template/bootstrap.sh" ];
  postCheck = ''
    # The stage-0 suites above ran under bash 3.2 as well.
    [[ $("$DS_BASH32" --version) == *"version 3.2.57"* ]]
    shellcheck -x cli/commands/preflight.sh cli/commands/bootstrap.sh cli/lib/stage0.sh \
      tools/gen-stage0.sh template/bootstrap.sh tests/cli/bootstrap/*.sh
  '';
}
