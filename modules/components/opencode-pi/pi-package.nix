# The Pi coding agent built from source, pinned by versions.lock.json
# (agent_tools.pi): the official source tag, the npm dependency hash of the
# upstream workspace lock and the model data of the pi-ai package of the
# same version. The published npm tarball is not used: its shrinkwrap lacks
# the integrities of the internal workspace packages.
#
#   pkgs  nixpkgs of the instance
#   pin   FIELD -> the value of agent_tools.pi.FIELD (dsLib.pinAt, so a
#         missing field names the lock path and the component)
#
# No PI_* default is set: the wrapper only puts ripgrep and fd on PATH.
{ pkgs, pin }:
pkgs.buildNpmPackage (finalAttrs: {
  pname = "pi-coding-agent";
  version = pin "version";
  nodejs = pkgs.nodejs_22;

  src = pkgs.fetchFromGitHub {
    owner = "earendil-works";
    repo = "pi";
    tag = "v${finalAttrs.version}";
    hash = pin "source_nix_sha256";
  };

  npmDepsHash = pin "npm_dependencies_nix_sha256";

  modelData = pkgs.fetchurl {
    url = "https://registry.npmjs.org/@earendil-works/pi-ai/-/pi-ai-${finalAttrs.version}.tgz";
    hash = pin "model_data_nix_sha256";
  };

  preConfigure = ''
    mkdir -p packages/ai/src/providers/data
    tar --extract --gzip --file=${finalAttrs.modelData} \
      --directory=packages/ai/src/providers/data \
      --strip-components=4 \
      package/dist/providers/data
  '';

  npmWorkspace = "packages/coding-agent";
  npmRebuildFlags = [ "--ignore-scripts" ];
  nativeBuildInputs = [
    pkgs.makeBinaryWrapper
    pkgs.jq
  ];

  buildPhase = ''
    runHook preBuild
    npm run build:offline
    runHook postBuild
  '';

  # The workspace packages are symlinks into the build tree: replace each
  # with a copy, then drop the links that would dangle in the output. The
  # workspaces are those of the release: every package.json below packages/
  # that is published (not "private", such as the evals); the coding agent
  # is the package itself. A release that drops or adds one builds as it is.
  postInstall = ''
    local nm="$out/lib/node_modules/pi-monorepo/node_modules" manifest dir name
    for manifest in packages/*/package.json; do
      dir=''${manifest%/package.json}
      [[ $dir != "$npmWorkspace" ]] || continue
      [[ $(jq -r '.private // false' "$manifest") != true ]] || continue
      name=$(jq -r '.name // empty' "$manifest")
      if [[ -z $name ]]; then
        echo "pi-package.nix: $manifest has no name; the workspaces of this Pi release are not what the package expects" >&2
        exit 1
      fi
      if [[ ! -L $nm/$name ]]; then
        echo "pi-package.nix: $name ($dir) is not linked in node_modules; the npm layout of this Pi release is not what the package expects" >&2
        exit 1
      fi
      rm "$nm/$name"
      cp -r "$dir" "$nm/$name"
    done
    find "$nm" -type l -lname '*/packages/*' -delete
    find "$nm/.bin" -xtype l -delete
  '';

  postFixup = ''
    wrapProgram $out/bin/pi --prefix PATH : ${
      pkgs.lib.makeBinPath [
        pkgs.ripgrep
        pkgs.fd
      ]
    }
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [
    pkgs.writableTmpDirAsHomeHook
    pkgs.versionCheckHook
  ];
  versionCheckKeepEnvironment = [ "HOME" ];
  versionCheckProgram = "${placeholder "out"}/bin/pi";
  versionCheckProgramArg = "--version";

  meta = {
    description = "Coding agent CLI with read, bash, edit, write tools and session management";
    homepage = "https://pi.dev/";
    license = pkgs.lib.licenses.mit;
    mainProgram = "pi";
  };
})
