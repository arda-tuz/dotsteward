# shellcheck shell=bash
# shellcheck disable=SC2016 # Nix expressions and jq programs in single quotes
# dotstewardManifest (3.7): the generation manifest per system with the
# instance-level values mkInstance adds, valid against
# schema/manifest.schema.json; dotstewardMirrors: the committed mirror of
# the manifest (.dotsteward/manifest.<system>.json).
# shellcheck source=tests/nix/instance/helpers.sh
source "$DS_REPO_ROOT/tests/nix/instance/helpers.sh"

schema=$DS_REPO_ROOT/schema/manifest.schema.json
python=$(nix_lib_jsonschema_python)

# validate FILE: FILE is valid against the manifest schema.
validate() {
  "$python" - "$schema" "$1" <<'EOF' || ds_fail "manifest $1 is not valid against the schema"
import json, sys
import jsonschema
schema = json.load(open(sys.argv[1]))
jsonschema.Draft202012Validator.check_schema(schema)
errors = sorted(jsonschema.Draft202012Validator(schema).iter_errors(json.load(open(sys.argv[2]))), key=str)
for error in errors:
    print(f"{list(error.absolute_path)}: {error.message}", file=sys.stderr)
sys.exit(1 if errors else 0)
EOF
}

# The generation manifest: Home Manager's dotsteward.manifest of the check
# identity, with pinned_versions and the framework facts.
for system in x86_64-linux aarch64-darwin; do
  file=$DS_TEST_ROOT/manifest.$system.json
  inst_json "storeless example.dotstewardManifest.$system" >"$file"
  validate "$file"
  json_check "$(<"$file")" '[.schema_version, .system, .config.instance.name, (.components | map(.name))]' \
    "[1,\"$system\",\"workstation\",[\"example-term\",\"example-app\"]]"
done
inst_json 'storeless minimal.dotstewardManifest.x86_64-linux' >"$DS_TEST_ROOT/minimal.json"
validate "$DS_TEST_ROOT/minimal.json"

assert_inst_eq 'true' \
  'storeless example.dotstewardManifest.x86_64-linux == storeless example.homeConfigurations.alice.config.dotsteward.manifest' \
  "the manifest of the check configuration"
assert_inst_eq 'true' \
  'example.dotstewardManifest.x86_64-linux.pinned_versions == example.lib.pinnedVersions' "pinned_versions"
version=$(<"$DS_REPO_ROOT/VERSION")
assert_inst_eq "{\"version\":\"$version\",\"rev\":null,\"narHash\":null}" \
  'example.dotstewardManifest.x86_64-linux.framework' "framework facts without a revision"
assert_inst_eq "{\"version\":\"$version\",\"rev\":\"0123456789abcdef0123456789abcdef01234567\",\"narHash\":\"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\"}" \
  'let
    framework = {
      outPath = repoRoot;
      rev = "0123456789abcdef0123456789abcdef01234567";
      narHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    };
    fwLib = import (repoRoot + "/lib") { dotsteward = framework; nixpkgs = nixpkgsInput; home-manager = homeManagerInput; };
    i = fwLib.mkInstance { root = exampleRoot; inputs = inputsFor exampleRoot; };
  in i.dotstewardManifest.x86_64-linux.framework' "framework facts with a revision"
# skills.framework_manifest carries the framework's skills/manifest.json
# when the framework ships one, and is null otherwise.
if [[ -f $DS_REPO_ROOT/skills/manifest.json ]]; then
  assert_inst_eq "$(jq -c . "$DS_REPO_ROOT/skills/manifest.json")" \
    'example.dotstewardManifest.x86_64-linux.skills.framework_manifest' "framework skills manifest"
else
  assert_inst_eq 'null' 'example.dotstewardManifest.x86_64-linux.skills.framework_manifest' \
    "no framework skills manifest"
fi

# A manifest that breaks the schema is refused by it (the schema is not
# vacuous).
jq '.schema_version = 2 | del(.components)' "$DS_TEST_ROOT/minimal.json" >"$DS_TEST_ROOT/broken.json"
if "$python" - "$schema" "$DS_TEST_ROOT/broken.json" <<'EOF' 2>/dev/null; then
import json, sys
import jsonschema
jsonschema.validate(json.load(open(sys.argv[2])), json.load(open(sys.argv[1])), cls=jsonschema.Draft202012Validator)
EOF
  ds_fail "the schema accepted schema_version 2 without components"
fi

# Mirrors: one manifest per system and one stage-0 file per platform.
assert_inst_eq '["manifest.aarch64-darwin.json","manifest.x86_64-linux.json","stage0.darwin.env","stage0.linux.env"]' \
  'builtins.attrNames example.dotstewardMirrors' "example mirror names"
assert_inst_eq '["manifest.x86_64-linux.json","stage0.linux.env"]' \
  'builtins.attrNames minimal.dotstewardMirrors' "minimal mirror names"

# The manifest mirror is the manifest as pretty JSON (sorted keys, two-space
# indent, final newline) without the framework revision, with store paths
# replaced by stable names: <instance>/<path> inside the instance root,
# <dotsteward>/<path> inside the framework source, <store>/<name> elsewhere.
mirror=$DS_TEST_ROOT/mirror.json
inst_raw 'example.dotstewardMirrors."manifest.x86_64-linux.json"' >"$mirror"
validate "$mirror"
assert_eq "$(jq -S --indent 2 . "$mirror")" "$(cat "$mirror")" "pretty JSON"
[[ $(tail -c 1 "$mirror" | od -An -c | tr -d ' ') == '\n' ]] || ds_fail "the mirror lacks a final newline"
store=$(inst_raw 'builtins.storeDir')
assert_not_contains "$(<"$mirror")" "$store/" "no store path in the mirror"
json_check "$(<"$mirror")" '[.framework, .checks.e2e[0].script, .agent_rules.source]' \
  "[{\"version\":\"$version\"},\"<store>/hook.sh\",\"<store>/AGENTS.md\"]"
assert_eq "$(jq -S 'del(.framework, .checks.e2e[0].script, .agent_rules.source)' "$DS_TEST_ROOT/manifest.x86_64-linux.json")" \
  "$(jq -S 'del(.framework, .checks.e2e[0].script, .agent_rules.source)' "$mirror")" "mirror content"

# Store paths inside the instance root and the framework source keep their
# relative path; other store paths keep their name.
assert_inst_eq '["<instance>/components/example-app/hook.sh","<dotsteward>/modules/core/default.nix","<store>/home.nix","x <store>/hook.sh/y","plain"]' \
  'let
    root = toString exampleRoot;
    framework = toString repoRoot;
    rendered = builtins.fromJSON (manifestLib.mirrorText {
      inherit root framework;
      manifest = {
        framework = { version = "1"; rev = "x"; narHash = "y"; };
        values = [
          "${root}/components/example-app/hook.sh"
          "${framework}/modules/core/default.nix"
          "${exampleRoot + "/home.nix"}"
          "x ${exampleRoot + "/components/example-app/hook.sh"}/y"
          "plain"
        ];
      };
    });
  in rendered.values' "store path replacement"
assert_inst_eq '{"version":"1"}' \
  '(builtins.fromJSON (manifestLib.mirrorText { root = "/r"; framework = "/f"; manifest.framework = { version = "1"; rev = "x"; narHash = null; }; })).framework' \
  "framework revision dropped"
