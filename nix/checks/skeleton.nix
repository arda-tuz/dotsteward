# Skeleton: dispatcher, version command, test runner and harness
# (tests/skeleton), plus the packaged CLI started with an empty environment,
# which proves the wrapper brings its own toolchain and baked source info.
{
  self,
  pkgs,
  system,
  lib,
  dsLib,
}:
let
  cli = dsLib.mkCli pkgs;
  expected = lib.concatStringsSep "\n" [
    "dotsteward ${dsLib.version}"
    "rev: ${self.rev or self.dirtyRev or "unknown"}"
    "narHash: ${self.narHash or "unknown"}"
  ];
in
cli.mkTestCheck {
  name = "skeleton";
  paths = [ "tests/skeleton" ];
  postCheck = ''
    actual=$(env -i ${lib.getExe cli} version)
    expected=${lib.escapeShellArg expected}
    if [[ $actual != "$expected" ]]; then
      printf 'packaged version output on %s:\n%s\nexpected:\n%s\n' ${system} "$actual" "$expected" >&2
      exit 1
    fi
  '';
}
