# template/bootstrap.sh is the stage-0 that tools/gen-stage0.sh generates
# from the stage-0 body of cli/commands/preflight.sh and cli/lib/stage0.sh:
# this check fails when the committed file differs (bytes or
# the executable bit). It reads the unpatched flake source, so the
# template's shebang is compared as committed.
{
  self,
  pkgs,
  ...
}:
pkgs.runCommand "dotsteward-check-stage0-generated"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gnused
      pkgs.diffutils
    ];
  }
  ''
    bash ${self}/tools/gen-stage0.sh --check --root ${self}
    touch "$out"
  ''
