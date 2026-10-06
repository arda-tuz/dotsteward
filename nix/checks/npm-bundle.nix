# mkNpmBundle (lib/npm-bundle.nix) builds a working bundle from the
# synthetic fixture tests/fixtures/npm-bundle: the dependencies are
# installed offline, exactly the declared commands are wrapped, PATH starts
# with nodejs and then the declared extra entries, the bundle keeps
# node_modules, package.json and package-lock.json, and the wrappers run in
# the sandbox with an empty environment.
#
# The fixture's only dependency, example-tools, is a reproducible tarball
# built from text sources (fixed output). A regular derivation serves it from
# a loopback HTTP registry and runs prefetch-npm-deps, the tool fetchNpmDeps
# runs, to build the npm cache; the bundle receives it as npmDeps, so the
# check needs no network. Changing example-tools changes the tarball hash
# below and the integrity in bundle/package-lock.json.
{
  pkgs,
  lib,
  dsLib,
  ...
}:
let
  fixture = ../../tests/fixtures/npm-bundle;

  # The resolved URL of example-tools in bundle/package-lock.json.
  registryPort = "47613";

  tarball =
    pkgs.runCommand "example-tools-1.2.3.tgz"
      {
        nativeBuildInputs = [
          pkgs.gnutar
          pkgs.gzip
        ];
        outputHashMode = "flat";
        outputHashAlgo = "sha256";
        outputHash = "sha256-VRPDaAIt1UpqOdM5jHTYs/mx1nzkjLKsnvQnnkZoGtE=";
      }
      ''
        mkdir package
        cp -R ${fixture + "/example-tools"}/. package/
        find package -type d -exec chmod 0755 {} +
        find package -type f -exec chmod 0644 {} +
        tar --format=ustar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
          -cf - package | gzip -9n >"$out"
      '';

  npmDeps =
    pkgs.runCommand "example-bundle-npm-deps"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.prefetch-npm-deps
        ];
      }
      ''
        mkdir -p registry/example-tools/-
        cp ${tarball} registry/example-tools/-/example-tools-1.2.3.tgz
        python3 -m http.server ${registryPort} --bind 127.0.0.1 --directory registry 2>server.log &
        server=$!
        trap 'kill "$server"' EXIT
        for _ in $(seq 100); do
          if python3 -c 'import socket; socket.create_connection(("127.0.0.1", ${registryPort}), 1)' 2>/dev/null; then
            break
          fi
          sleep 0.1
        done
        prefetch-npm-deps ${fixture + "/bundle/package-lock.json"} "$out"
      '';

  runtime = pkgs.runCommand "example-term-runtime" { } ''mkdir -p "$out/bin"'';

  bundleWith =
    src:
    dsLib.mkNpmBundle {
      inherit pkgs npmDeps src;
      pname = "example-bundle";
      version = "1.0.0";
      nodejs = pkgs.nodejs_22;
      commands = [
        "example-app"
        "example-term"
      ];
      extraPath.example-term = [
        runtime
        "/opt/example/bin"
      ];
    };

  bundle = bundleWith (fixture + "/bundle");

  # A string naming a directory inside a store path, as an instance writes
  # root + "/packages/<name>", gives the same derivation as the path.
  sameFromSubpath = (bundleWith "${fixture}/bundle").drvPath == bundle.drvPath;
in
pkgs.runCommand "dotsteward-check-npm-bundle" { } ''
  set -euo pipefail
  fail() {
    printf 'npm-bundle: %s\n' "$*" >&2
    exit 1
  }
  expect() {
    [[ $2 == "$3" ]] || fail "$1: expected [$3], got [$2]"
  }
  bundle=${bundle}
  root=$bundle/lib/example-bundle

  expect "derivation from a store subpath source" ${lib.boolToString sameFromSubpath} true

  expect "wrappers" "$(cd "$bundle/bin" && printf '%s ' *)" "example-app example-term "
  for entry in node_modules package.json package-lock.json; do
    [[ -e $root/$entry ]] || fail "missing lib/example-bundle/$entry"
  done
  [[ -L $root/node_modules/.bin/alpha ]] || fail "the undeclared bin alpha is missing from node_modules/.bin"

  expect "example-app" "$(env -i "$bundle/bin/example-app")" "example-app 1.2.3"
  expect "example-term" "$(env -i "$bundle/bin/example-term")" "example-term 1.2.3"
  # The inherited PATH stays after the prefix.
  expect "example-app PATH" "$(env -i PATH=/example/bin "$bundle/bin/example-app" --path)" \
    "${pkgs.nodejs_22}/bin:/example/bin"
  expect "example-term PATH" "$(env -i PATH=/example/bin "$bundle/bin/example-term" --path)" \
    "${pkgs.nodejs_22}/bin:${runtime}/bin:/opt/example/bin:/example/bin"

  touch "$out"
''
