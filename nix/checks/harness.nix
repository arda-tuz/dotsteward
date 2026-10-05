# Test harness (tests/harness): the generic stubs, the git, SSH and HTTP
# helpers and the shared fixtures. The stub files have no .sh suffix, so the
# CI lint glob never sees them; shellcheck runs over every harness shell file
# here instead, and httpfix.py gets a syntax check.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
in
cli.mkTestCheck {
  name = "harness";
  paths = [ "tests/harness" ];
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x tests/lib/harness.sh tests/lib/assert.sh tests/lib/bare-remote.sh \
      tests/lib/fakessh.sh tests/lib/stubs/* tests/harness/*.sh
    python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' tests/lib/httpfix.py
  '';
}
