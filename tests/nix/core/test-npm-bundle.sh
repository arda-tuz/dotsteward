# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # Nix expressions and expected shell text in single quotes
# lib/npm-bundle.nix: mkNpmBundle evaluates to the buildNpmPackage
# derivation a hand-written recipe gives (same installPhase bytes, same
# drvPath), and rejects invalid arguments. checks.npm-bundle builds one.
# shellcheck source=tests/nix/core/helpers.sh
source "$DS_REPO_ROOT/tests/nix/core/helpers.sh"

# A synthetic bundle: six commands (the list wraps), extra PATH entries for
# two of them (a package and a literal directory).
scope='let
  pkgs = pkgsFor "x86_64-linux";
  marker = pkgs.runCommand "example-term-runtime" { } "mkdir -p $out/bin";
  src = repoRoot + "/tests/fixtures/npm-bundle/bundle";
  npmDepsHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  commands = [ "example-app" "example-term" "example-app-alpha" "example-app-beta" "example-term-gamma" "example-term-delta" ];
  extraPath = { example-term = [ marker ]; example-app-beta = [ "/opt/example/bin" marker ]; };
  bundle = args: dsLib.mkNpmBundle ({ inherit pkgs src npmDepsHash commands extraPath; pname = "example-bundle"; version = "1.0.0"; nodejs = pkgs.nodejs_22; } // args);
in'

expected=$(
  cat <<'EOF'
runHook preInstall
install_root="$out/lib/example-bundle"
mkdir -p "$install_root" "$out/bin"
cp -R node_modules package.json package-lock.json "$install_root/"
for command_name in \
  example-app example-term example-app-alpha example-app-beta example-term-gamma \
  example-term-delta; do
  runtime_path="@NODEJS@/bin"
  if [[ "$command_name" == example-term ]]; then
    runtime_path="$runtime_path:@MARKER@/bin"
  fi
  if [[ "$command_name" == example-app-beta ]]; then
    runtime_path="$runtime_path:/opt/example/bin:@MARKER@/bin"
  fi
  makeWrapper "$install_root/node_modules/.bin/$command_name" "$out/bin/$command_name" \
    --prefix PATH : "$runtime_path"
done
runHook postInstall
EOF
)
actual=$(core_json "$scope { phase = (bundle { }).installPhase; nodejs = \"\${pkgs.nodejs_22}\"; marker = \"\${marker}\"; }")
expected=${expected//@NODEJS@/$(jq -r .nodejs <<<"$actual")}
expected=${expected//@MARKER@/$(jq -r .marker <<<"$actual")}
# Compared as JSON strings, so the final newline counts.
assert_eq "$(jq -Rs . <<<"$expected")" "$(jq .phase <<<"$actual")" "installPhase bytes"

# The derivation equals a hand-written buildNpmPackage recipe with the same
# attributes, so an existing recipe keeps its store path.
reference='pkgs.buildNpmPackage {
  pname = "example-bundle";
  version = "1.0.0";
  inherit src npmDepsHash;
  nodejs = pkgs.nodejs_22;
  dontNpmBuild = true;
  nativeBuildInputs = [ pkgs.makeWrapper ];
  installPhase = (bundle { }).installPhase;
}'
assert_core_eq 'true' "$scope (bundle { }).drvPath == ($reference).drvPath"
assert_core_eq '"example-bundle-1.0.0"' "$scope (bundle { }).name"

# The source is copied on its own, named after its directory (a string
# naming a directory inside a store path gets the same treatment; that needs
# a real store, so checks.npm-bundle covers it).
assert_core_eq 'true' "$scope lib.hasSuffix \"-bundle\" \"\${(bundle { }).src}\""

# A single short command list stays on one line; nodejs defaults to
# pkgs.nodejs; meta passes through.
actual=$(core_json "$scope let b = dsLib.mkNpmBundle { inherit pkgs src npmDepsHash; pname = \"example-bundle\"; version = \"1.0.0\"; commands = [ \"example-app\" ]; meta.mainProgram = \"example-app\"; }; in { phase = b.installPhase; nodejs = \"\${pkgs.nodejs}\"; main = b.meta.mainProgram; }")
assert_contains "$(jq -r .phase <<<"$actual")" $'for command_name in \\\n  example-app; do\n  runtime_path="'"$(jq -r .nodejs <<<"$actual")"$'/bin"\n  makeWrapper'
json_check "$actual" .main '"example-app"'

# A prebuilt dependency cache replaces npmDepsHash.
assert_core_eq 'true' "$scope let deps = pkgs.runCommand \"example-bundle-npm-deps\" { } \"mkdir \$out\"; in (bundle { npmDepsHash = null; npmDeps = deps; }).npmDeps == deps"

# Invalid arguments name the problem.
fails() {
  assert_core_fails "$scope (bundle ($1)).drvPath" "dotsteward: mkNpmBundle example-bundle: $2"
}
fails '{ commands = [ ]; }' "commands must not be empty"
fails '{ commands = [ "example-app" "example-app" ]; }' "duplicate command example-app"
fails '{ commands = [ "../example-app" ]; }' 'invalid command name "../example-app"'
fails '{ commands = [ "example app" ]; }' 'invalid command name "example app"'
fails '{ extraPath = { example-unknown = [ "/opt/bin" ]; }; }' "extraPath names example-unknown, which is not a command"
fails '{ extraPath = { example-term = [ "relative/bin" ]; }; }' 'extraPath of example-term: "relative/bin" is neither a package nor a plain absolute directory'
fails '{ extraPath = { example-term = [ "/opt/\"quoted\"/bin" ]; }; }' 'extraPath of example-term: "/opt/\"quoted\"/bin" is neither a package nor a plain absolute directory'
fails '{ npmDepsHash = null; }' "set exactly one of npmDepsHash and npmDeps"
fails '{ npmDeps = pkgs.emptyDirectory; }' "set exactly one of npmDepsHash and npmDeps"
