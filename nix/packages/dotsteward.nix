# mkCli: builds the dotsteward CLI with a given nixpkgs.
#
# The framework calls it with its own nixpkgs (packages.<system>.dotsteward);
# an instance calls it with the instance nixpkgs, so the Python engines run
# with the instance's python and tomlkit. Bash commands run with the
# toolchain below (cosign among it) first on PATH on every platform;
# everything else (ssh, sudo, platform package managers, catalog CLIs)
# resolves from the inherited PATH.
#
# The package copies the files of nix/packages/dotsteward-files.nix (cli/,
# engines/, skills/manifest.json, privacy/, schema/, VERSION, template/ and
# the component seeds modules/components/*/seed.json) and bakes the
# framework rev and narHash into share/dotsteward/source-info for
# `dotsteward version`. Of modules/ it ships only the seeds, so the
# packaged modules/components directories are not the catalog:
# share/dotsteward/catalog.json lists the catalog component names (the
# source's modules/components directories, as lib.catalog), and the Python
# configuration reader takes its default catalog from it.
{
  version,
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
    # Verifies the sigstore signatures the lock records, offline (cli/lib/methods.sh,
    # pins apply).
    pkgs.cosign
    python
  ];

  source = fs.toSource {
    inherit root;
    fileset = import ./dotsteward-files.nix { inherit lib; };
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

  # mkTestCheck { name, paths, source ? name, nativeBuildInputs ? [ ],
  #               postCheck ? "", keepShebangs ? [ ], platform ? null }:
  # a check that runs `tests/run.sh PATHS...` on a writable copy of its
  # source set in the build sandbox, with the CLI toolchain on PATH and as
  # many test files at once as the build has cores (NIX_BUILD_CORES), then
  # the shell snippet postCheck. DS_TOOLCHAIN_PATH names the toolchain, as
  # in the dev shell (nix/outputs.nix). A platform (linux or darwin) forces the
  # platform every test sees (DS_TEST_PLATFORM of tests/lib/harness.sh).
  # The derivation passes paths, nativeBuildInputs and keepShebangs on
  # (passthru), so a check can run the suites of others
  # (checks.darwin-platform). Used by nix/checks/*.nix. The source set is
  # the entry `source` of nix/check-sources.nix, the files the check reads,
  # so a change to any other file of the tree leaves the check as it is; a
  # set without VERSION gets the placeholder version 0.0.0. Executable files
  # get their shebangs patched to store paths (the sandbox has no
  # /usr/bin/env), except the keepShebangs paths (relative to the source
  # root): fixture data the tests compare byte for byte.
  mkTestCheck =
    {
      name,
      paths,
      source ? name,
      nativeBuildInputs ? [ ],
      postCheck ? "",
      keepShebangs ? [ ],
      platform ? null,
    }:
    let
      checkSources = import ../check-sources.nix { inherit lib; };
      src = checkSources.sources.${source};
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
        passthru = {
          inherit
            src
            paths
            nativeBuildInputs
            keepShebangs
            ;
        };
      }
      ''
        cp -R ${src} source
        chmod -R u+w source
        cd source
        ${lib.optionalString (!checkSources.hasVersion source) "printf '0.0.0\\n' >VERSION"}
        ${patchShebangsCommand}
        # The toolchain, named for the tests and tools that put it first again (tools/gen-docs.sh).
        export DS_TOOLCHAIN_PATH=${lib.escapeShellArg (lib.makeBinPath toolchain)}
        ${lib.optionalString (platform != null) "export DS_TEST_PLATFORM=${lib.escapeShellArg platform}"}
        bash tests/run.sh --jobs "$NIX_BUILD_CORES" ${lib.escapeShellArgs paths}
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
    # The toolchain goes first on PATH for the CLI's own code and is named
    # in DOTSTEWARD_TOOLCHAIN_PATH, so the checks of the user's environment
    # leave it out (user_path in cli/lib/lib.sh).
    makeWrapper "$out/share/dotsteward/cli/dotsteward" "$out/bin/dotsteward" \
      --set DOTSTEWARD_TOOLCHAIN_PATH ${lib.escapeShellArg (lib.makeBinPath toolchain)} \
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
