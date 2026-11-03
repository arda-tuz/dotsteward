# Skeleton: dispatcher, version command, test runner and harness
# (tests/skeleton), plus the packaged CLI started with an empty environment,
# which proves the wrapper brings its own toolchain and baked source info:
# the checks see the framework without its commit (nix/outputs.nix), so
# their CLI reports no revision, and a CLI built for a fixture commit
# reports that one.
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
    rev = "0123456789abcdef0123456789abcdef01234567";
    narHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };
  baked = import ../packages/dotsteward.nix (
    {
      inherit (dsLib) version;
      src = self;
    }
    // fixture
  ) pkgs;
  versionOutput =
    rev: narHash:
    lib.concatStringsSep "\n" [
      "dotsteward ${dsLib.version}"
      "rev: ${rev}"
      "narHash: ${narHash}"
    ];
in
cli.mkTestCheck {
  name = "skeleton";
  paths = [ "tests/skeleton" ];
  postCheck = ''
    # check_version CLI EXPECTED: the version output of CLI, started with an
    # empty environment, is EXPECTED.
    check_version() {
      local actual
      actual=$(env -i "$1" version)
      if [[ $actual != "$2" ]]; then
        printf 'packaged version output on %s:\n%s\nexpected:\n%s\n' ${system} "$actual" "$2" >&2
        exit 1
      fi
    }
    check_version ${lib.getExe cli} ${lib.escapeShellArg (versionOutput "unknown" "unknown")}
    check_version ${lib.getExe baked} ${lib.escapeShellArg (versionOutput fixture.rev fixture.narHash)}
    # The wrapper names the toolchain it puts first on PATH, so the checks of
    # the user's environment can leave it out (user_path in cli/lib/lib.sh).
    toolchain=$(sed -n "s/^export DOTSTEWARD_TOOLCHAIN_PATH='\(.*\)'$/\1/p" ${lib.getExe cli})
    for tool in jq python3 git; do
      found=0
      IFS=: read -ra dirs <<<"$toolchain"
      for dir in "''${dirs[@]}"; do
        [[ -x $dir/$tool ]] && found=1
      done
      if ((!found)); then
        printf 'the packaged CLI on %s does not name the directory of its %s in DOTSTEWARD_TOOLCHAIN_PATH: %s\n' \
          ${system} "$tool" "$toolchain" >&2
        exit 1
      fi
    done
  '';
}
