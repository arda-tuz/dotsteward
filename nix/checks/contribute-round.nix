# Contribute round (tests/contribute/round): the changes published through
# `dotsteward contribute` itself, starting with `dotsteward version --json`,
# plus the packaged CLI's JSON started with an empty environment, which must
# carry the baked source info. Then shellcheck over the tests.
{
  self,
  pkgs,
  system,
  lib,
  dsLib,
}:
let
  cli = dsLib.mkCli pkgs;
  # builtins.toJSON sorts the keys, as `jq -cS` does.
  expected = builtins.toJSON {
    version = dsLib.version;
    rev = self.rev or self.dirtyRev or null;
    narHash = self.narHash or null;
  };
in
cli.mkTestCheck {
  name = "contribute-round";
  paths = [ "tests/contribute/round" ];
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x tests/contribute/round/*.sh
    actual=$(env -i ${lib.getExe cli} version --json | jq -cS .)
    expected=${lib.escapeShellArg expected}
    if [[ $actual != "$expected" ]]; then
      printf 'packaged version --json output on %s:\n%s\nexpected:\n%s\n' ${system} "$actual" "$expected" >&2
      exit 1
    fi
  '';
}
