# Gate (tests/cli/gate): `dotsteward gate` and cli/lib/txn.sh against a
# synthetic instance with a bare remote, the nix and curl stubs and fake
# static, pins and probes commands (arguments and repository guards, lock,
# untracked files, base, update allowlist, candidate tree, memo, the five
# steps, preflight, cli-probes and the framework override), then shellcheck
# over the command, the library and the tests.
{
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;
in
cli.mkTestCheck {
  name = "cli-gate";
  paths = [ "tests/cli/gate" ];
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x cli/lib/txn.sh cli/commands/gate.sh tests/cli/gate/*.sh
  '';
}
