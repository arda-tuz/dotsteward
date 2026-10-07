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
