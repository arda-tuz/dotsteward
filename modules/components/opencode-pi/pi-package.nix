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
  nativeBuildInputs = [ pkgs.makeBinaryWrapper ];

  buildPhase = ''
    runHook preBuild
    npm run build:offline
    runHook postBuild
  '';

  # The workspace packages are symlinks into the build tree: replace each
  # with a copy, then drop the links that would dangle in the output.
  postInstall = ''
    local nm="$out/lib/node_modules/pi-monorepo/node_modules"
    for ws in @earendil-works/chord:packages/chord \
              @earendil-works/pi-ai:packages/ai \
              @earendil-works/pi-agent-core:packages/agent \
              @earendil-works/pi-client:packages/client \
              @earendil-works/pi-codemode:packages/codemode \
              @earendil-works/pi-durable:packages/durable \
              @earendil-works/pi-mcp:packages/mcp \
              @earendil-works/pi-protocol:packages/protocol \
              @earendil-works/pi-server:packages/server \
              @earendil-works/pi-telemetry:packages/telemetry \
              @earendil-works/pi-tui:packages/tui; do
      IFS=: read -r pkg src <<< "$ws"
      rm "$nm/$pkg"
      cp -r "$src" "$nm/$pkg"
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
