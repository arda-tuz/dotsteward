# Contribute round (tests/contribute/round): the changes published through
# `dotsteward contribute` itself, starting with `dotsteward version --json`,
# the CI it waits for (the workflows' events and jobs) and the version tool
# (tools/version.sh: the copies of VERSION, semantic versions, notes), plus
# the packaged CLI's JSON started with an empty environment, which must
# carry the baked source info: null for the CLI of the checks, which see the
# framework without its commit (nix/outputs.nix), and the fixture commit
# for a CLI built for it. Then shellcheck over the tests and the tool.
{
  self,
  pkgs,
  system,
  lib,
  dsLib,
}:
let
  cli = dsLib.mkCli pkgs;
  fixture = {
    rev = "89abcdef0123456789abcdef0123456789abcdef";
    narHash = "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=";
  };
  baked = import ../packages/dotsteward.nix (
    {
      inherit (dsLib) version;
      src = self;
    }
    // fixture
  ) pkgs;
  # builtins.toJSON sorts the keys, as `jq -cS` does.
  versionJson =
    { rev, narHash }:
    builtins.toJSON {
      inherit (dsLib) version;
      inherit rev narHash;
    };
  unbaked = versionJson {
    rev = null;
    narHash = null;
  };
in
cli.mkTestCheck {
  name = "contribute-round";
  paths = [ "tests/contribute/round" ];
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x tests/contribute/round/*.sh tools/version.sh cli/lib/release.sh
    # check_json CLI EXPECTED: `version --json` of CLI, started with an empty
    # environment, is EXPECTED (compact, sorted keys).
    check_json() {
      local actual
      actual=$(env -i "$1" version --json | jq -cS .)
      if [[ $actual != "$2" ]]; then
        printf 'packaged version --json output on %s:\n%s\nexpected:\n%s\n' ${system} "$actual" "$2" >&2
        exit 1
      fi
    }
    check_json ${lib.getExe cli} ${lib.escapeShellArg unbaked}
    check_json ${lib.getExe baked} ${lib.escapeShellArg (versionJson fixture)}
  '';
}
