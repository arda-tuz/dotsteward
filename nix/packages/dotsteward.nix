# mkCli: builds the dotsteward CLI with a given nixpkgs.
#
# The framework calls it with its own nixpkgs (packages.<system>.dotsteward);
# an instance calls it with the instance nixpkgs, so the Python engines run
# with the instance's python and tomlkit (F8). Bash commands run with the
# toolchain below first on PATH on every platform (F3); everything else
# (ssh, sudo, platform package managers, catalog CLIs) resolves from the
# inherited PATH.
#
# The package copies cli/, engines/, skills/manifest.json, privacy/, schema/
# and VERSION by directory (missing ones are skipped), so new command files
# need no edit here, and bakes the framework rev and narHash into
# share/dotsteward/source-info for `dotsteward version`.
{
  version,
  src,
  rev,
  narHash,
}:
pkgs:
let
  inherit (pkgs) lib;
  fs = lib.fileset;

  root = ../..;

  python = pkgs.python3.withPackages (ps: [ ps.tomlkit ]);

  # Only flock from util-linux: the rest of util-linux must not shadow the
  # host's tools.
  flock =
    if pkgs.stdenv.hostPlatform.isLinux then
      pkgs.runCommand "flock-${pkgs.util-linux.version}" { } ''
        mkdir -p "$out/bin"
        ln -s ${lib.getExe' pkgs.util-linux "flock"} "$out/bin/flock"
      ''
    else
      pkgs.flock;

  toolchain = [
    pkgs.bash
    pkgs.coreutils
    pkgs.findutils
    pkgs.gnugrep
    pkgs.gnused
    pkgs.gawk
    pkgs.jq
    pkgs.git
    flock
    pkgs.curl
    python
  ];

  source = fs.toSource {
    inherit root;
    fileset = fs.unions (
      [
        (root + "/VERSION")
        (root + "/cli")
      ]
      ++ map fs.maybeMissing [
        (root + "/engines")
        (root + "/skills/manifest.json")
        (root + "/privacy")
        (root + "/schema")
      ]
    );
  };

  sourceInfo = lib.concatStrings (
    lib.optional (rev != null) "rev=${rev}\n" ++ lib.optional (narHash != null) "narHash=${narHash}\n"
  );

  # mkTestCheck { name, paths, nativeBuildInputs ? [ ], postCheck ? "" }:
  # a check that runs `tests/run.sh PATHS...` on a writable copy of the
  # framework source in the build sandbox, with the CLI toolchain on PATH,
  # then the shell snippet postCheck. Used by nix/checks/*.nix.
  mkTestCheck =
    {
      name,
      paths,
      nativeBuildInputs ? [ ],
      postCheck ? "",
    }:
    pkgs.runCommand "dotsteward-check-${name}"
      {
        nativeBuildInputs = toolchain ++ nativeBuildInputs;
      }
      ''
        cp -R ${src} source
        chmod -R u+w source
        cd source
        patchShebangs --build . >/dev/null
        bash tests/run.sh ${lib.escapeShellArgs paths}
        ${postCheck}
        touch "$out"
      '';
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "dotsteward";
  inherit version;
  src = source;

  nativeBuildInputs = [ pkgs.makeWrapper ];
  # patchShebangs resolves `#!/usr/bin/env bash` against the host bash.
  buildInputs = [ pkgs.bash ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/dotsteward" "$out/bin"
    cp -R . "$out/share/dotsteward/"
    printf '%s' ${lib.escapeShellArg sourceInfo} >"$out/share/dotsteward/source-info"
    makeWrapper "$out/share/dotsteward/cli/dotsteward" "$out/bin/dotsteward" \
      --prefix PATH : ${lib.escapeShellArg (lib.makeBinPath toolchain)}
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    first_line=$(env -i "$out/bin/dotsteward" version | head -n 1)
    if [[ $first_line != ${lib.escapeShellArg "dotsteward ${version}"} ]]; then
      echo "unexpected version output: $first_line" >&2
      exit 1
    fi
    runHook postInstallCheck
  '';

  passthru = {
    inherit toolchain mkTestCheck;
  };

  meta = {
    description = "Reproducible agent workstations with Nix and Home Manager";
    license = lib.licenses.mit;
    mainProgram = "dotsteward";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
