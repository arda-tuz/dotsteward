# mkCli: builds the dotsteward CLI with a given nixpkgs.
#
# The framework calls it with its own nixpkgs (packages.<system>.dotsteward);
# an instance calls it with the instance nixpkgs, so the Python engines run
# with the instance's python and tomlkit (F8). Bash commands run with the
# toolchain below first on PATH on every platform (F3); everything else
# (ssh, sudo, platform package managers, catalog CLIs) resolves from the
# inherited PATH.
#
# The package copies cli/, engines/, skills/manifest.json, privacy/, schema/,
# VERSION and the template files `dotsteward static` compares instances with
# (template/.dotsteward/cli.sh, template/bootstrap.sh) by path (missing ones
# are skipped), so new command files need no edit here, and bakes the
# framework rev and narHash into share/dotsteward/source-info for
# `dotsteward version`. It has no modules/ directory, so
# share/dotsteward/catalog.json lists the catalog component names (the
# modules/components directories, as lib.catalog), which the Python
# configuration reader uses as its default catalog.
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
        (root + "/template/.dotsteward/cli.sh")
        (root + "/template/bootstrap.sh")
      ]
    );
  };

  componentsDir = root + "/modules/components";
  catalogNames =
    if builtins.pathExists componentsDir then
      lib.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir componentsDir))
    else
      [ ];

  sourceInfo = lib.concatStrings (
    lib.optional (rev != null) "rev=${rev}\n" ++ lib.optional (narHash != null) "narHash=${narHash}\n"
  );

  # mkTestCheck { name, paths, nativeBuildInputs ? [ ], postCheck ? "",
  #               keepShebangs ? [ ] }:
  # a check that runs `tests/run.sh PATHS...` on a writable copy of the
  # framework source in the build sandbox, with the CLI toolchain on PATH,
  # then the shell snippet postCheck. Used by nix/checks/*.nix. Executable
  # files get their shebangs patched to store paths (the sandbox has no
  # /usr/bin/env), except the keepShebangs paths (relative to the source
  # root): fixture data the tests compare byte for byte.
  mkTestCheck =
    {
      name,
      paths,
      nativeBuildInputs ? [ ],
      postCheck ? "",
      keepShebangs ? [ ],
    }:
    let
      patchShebangsCommand =
        if keepShebangs == [ ] then
          "patchShebangs --build . >/dev/null"
        else
          ''
            mapfile -d "" patchable < <(find . -type f -perm -0100 ${
              lib.concatMapStringsSep " " (path: "! -path ${lib.escapeShellArg "./${path}"}") keepShebangs
            } -print0)
            patchShebangs --build "''${patchable[@]}" >/dev/null
          '';
    in
    pkgs.runCommand "dotsteward-check-${name}"
      {
        nativeBuildInputs = toolchain ++ nativeBuildInputs;
      }
      ''
        cp -R ${src} source
        chmod -R u+w source
        cd source
        ${patchShebangsCommand}
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
  # Only the commands get store shebangs: the template files stay byte for
  # byte the framework's, which `dotsteward static` compares instances with
  # and `dotsteward init` copies.
  dontPatchShebangs = true;

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/dotsteward" "$out/bin"
    cp -R . "$out/share/dotsteward/"
    patchShebangs --host "$out/share/dotsteward/cli"
    printf '%s' ${lib.escapeShellArg sourceInfo} >"$out/share/dotsteward/source-info"
    printf '%s\n' ${lib.escapeShellArg (builtins.toJSON catalogNames)} >"$out/share/dotsteward/catalog.json"
    makeWrapper "$out/share/dotsteward/cli/dotsteward" "$out/bin/dotsteward" \
      --prefix PATH : ${lib.escapeShellArg (lib.makeBinPath toolchain)}
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    # No pipe into head: head may exit after the first line while the
    # command still writes, and the broken pipe fails the build under
    # pipefail.
    first_line=$(env -i "$out/bin/dotsteward" version)
    first_line=''${first_line%%$'\n'*}
    if [[ $first_line != ${lib.escapeShellArg "dotsteward ${version}"} ]]; then
      echo "unexpected version output: $first_line" >&2
      exit 1
    fi
    # Template files are the source's bytes.
    if [[ -d template ]]; then
      while IFS= read -r -d "" file; do
        cmp -- "template/$file" "$out/share/dotsteward/template/$file"
      done < <(cd template && find . -type f -print0)
    fi
    # The configuration reader imports with the packaged python and reads
    # the packaged schema and catalog.
    env -i PYTHONPATH="$out/share/dotsteward/cli/python" PYTHONDONTWRITEBYTECODE=1 \
      ${python.interpreter} -s -P -c '
    import sys
    from dotsteward_cli import config
    assert str(config.FRAMEWORK_ROOT) == sys.argv[1], config.FRAMEWORK_ROOT
    assert config.schema()["title"] == "dotsteward workstation.toml"
    assert config.framework_catalog() == sys.argv[2:], config.framework_catalog()
    ' "$out/share/dotsteward" ${lib.escapeShellArgs catalogNames}
    runHook postInstallCheck
  '';

  passthru = {
    inherit toolchain mkTestCheck python;
  };

  meta = {
    description = "Reproducible agent workstations with Nix and Home Manager";
    license = lib.licenses.mit;
    mainProgram = "dotsteward";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
