# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # Nix expressions in single quotes
# components/example/default.nix.disabled (SPEC 10.1, 3.4): the annotated
# example of the full component contract for the synthetic example-term. Its
# suffix keeps it out of every instance; enabled the way components/README.md
# describes (copied to components/example-term/default.nix, a
# [components.example-term] table, its lock entries), it is a working
# private component on Linux and darwin: it sets every field of the
# contract, the manifest lists it with its resolved method, and the
# instance contract (static, the pins check of its rules, settings validate
# with its targets, the scan) passes.
# shellcheck source=tests/instance/template/helpers.sh
source "$DS_REPO_ROOT/tests/instance/template/helpers.sh"

command -v shellcheck >/dev/null 2>&1 || ds_fail "the template tests need shellcheck on PATH"

example=$tpl/components/example/default.nix.disabled
[[ -f $example ]] || ds_fail "template/components/example/default.nix.disabled is missing"
# Not imported as it is: only components/<name>/default.nix is a component.
[[ ! -e $tpl/components/example/default.nix ]] || ds_fail "the example must stay disabled in the template"

inst=$DS_TEST_ROOT/instance
template_instance "$inst"

# Enable it as components/README.md says.
readme=$tpl/components/README.md
for step in 'components/example-term/default.nix' '[components.example-term]' 'agent_tools.example-term'; do
  assert_contains "$(<"$readme")" "$step" "components/README.md explains the step"
done
mkdir -p "$inst/components/example-term"
cp "$example" "$inst/components/example-term/default.nix"
sed -i 's/^systems = \["x86_64-linux"\]$/systems = ["x86_64-linux", "aarch64-darwin"]/' "$inst/workstation.toml"
cat >>"$inst/workstation.toml" <<'TOML'

[components.example-term]
enable = true
options = { greeting = "hello from the example" }
TOML
# The release pins its official-binary rules read, one per platform.
jq '.agent_tools = {
  "example-term": {
    linux: {
      version: "1.4.0",
      url: "https://github.com/example-org/example-term/releases/download/v1.4.0/example-term-x86_64-linux.tar.gz",
      size: 1048576,
      sha256: "1111111111111111111111111111111111111111111111111111111111111111"
    },
    darwin: {
      version: "1.4.0",
      url: "https://github.com/example-org/example-term/releases/download/v1.4.0/example-term-aarch64-darwin.tar.gz",
      size: 1048576,
      sha256: "2222222222222222222222222222222222222222222222222222222222222222"
    }
  }
}' "$inst/versions.lock.json" >"$inst/versions.lock.json.new"
mv "$inst/versions.lock.json.new" "$inst/versions.lock.json"
rm -f "$inst"/.dotsteward/manifest.*.json "$inst"/.dotsteward/stage0.*.env
expr=$(instance_expr "$inst")
write_mirrors "$expr" "$inst"
commit_all "$inst" "feat(example-term): enable the example component"

# --- every field of the contract ------------------------------------------------

# The fields the example defines (its definition of dotsteward.components),
# against the options of the contract; enable, profiles and options are
# set by mkInstance from workstation.toml.
contract_coverage='let
  hm = (EXPR).lib.mkHome { username = "user"; homeDirectory = "/home/user"; profile = "workstation"; };
  option = hm.options.dotsteward.components;
  definitions = map (d: d.value.example-term) (builtins.filter
    (d: lib.hasSuffix "/components/example-term/default.nix" d.file && d.value ? example-term)
    option.definitionsWithLocations);
  defined = builtins.head definitions;
  visible = attrs: builtins.filter (name: !lib.hasPrefix "_" name) (builtins.attrNames attrs);
  sub = option.type.getSubOptions [ ];
  nested = [ "supportedMethods" "pins" "checks" "hooks" "bootstrap" "rebuild" "rollback" "preflight" "skillLayout" "gate" ];
  installed = builtins.attrNames defined.install;
in {
  count = builtins.length definitions;
  missing = lib.subtractLists ([ "enable" "profiles" "options" ] ++ visible defined) (visible sub);
  nestedMissing = lib.filterAttrs (_: names: names != [ ]) (lib.genAttrs nested (name:
    lib.subtractLists (visible defined.${name}) (visible (sub.${name}.type.getSubOptions [ ]))));
  installMissing = lib.genAttrs installed (method:
    lib.subtractLists (visible defined.install.${method})
      (visible (((sub.install.type.getSubOptions [ ]).${method}).type.getSubOptions [ ])));
  inherit installed;
  supported = defined.supportedMethods;
}'
coverage=$(inst_json "${contract_coverage//EXPR/$expr}")
assert_json - '.count == 1' "one definition from the example" <<<"$coverage"
assert_json - '.missing == []' "contract fields the example leaves out" <<<"$coverage"
assert_json - '.nestedMissing == {}' "nested contract fields the example leaves out" <<<"$coverage"
assert_json - '[.installMissing[]] | all(. == [])' "install fields the example leaves out" <<<"$coverage"
# An install block for every method it supports, and only those.
assert_json - '.installed == ([.supported.linux[], .supported.darwin[]] | unique)' \
  "install blocks of the supported methods" <<<"$coverage"

# --- evaluation on both systems ----------------------------------------------------

for system in x86_64-linux aarch64-darwin; do
  manifest=$(inst_json "($expr).dotstewardManifest.$system")
  assert_json - '[.components[] | {name, source, method}] == [{name: "example-term", source: "instance", method: "official-binary"}]' \
    "manifest components on $system" <<<"$manifest"
  assert_json - '.components[0].install.pin | startswith("agent_tools.example-term.")' \
    "the official-binary pin on $system" <<<"$manifest"
  assert_json - '.managed_links | index("~/.example-term/AGENTS.md") != null' "managed link on $system" <<<"$manifest"
done
assert_inst_eq '"hello from the example\n"' \
  "(homeOf ($expr) \"x86_64-linux\" \"workstation\").home.file.\".example-term/greeting\".text" \
  "the module reads its options"
assert_inst_eq '"official-binary"' \
  "(homeOf ($expr) \"aarch64-darwin\" \"fresh\").dotsteward.components.example-term.method" "darwin method"

# --- the instance contract with the example enabled --------------------------------

instance_contract "$inst" x86_64-linux
instance_contract "$inst" aarch64-darwin

# Its pin rules are real: a lock entry whose URL is not the declared release
# fails the pins check.
jq '.agent_tools["example-term"].linux.url = "https://downloads.example.invalid/example-term.tar.gz"' \
  "$inst/versions.lock.json" >"$inst/versions.lock.json.new"
mv "$inst/versions.lock.json.new" "$inst/versions.lock.json"
commit_all "$inst" "test: break the example pin"
assert_exit 1 "$DS_CLI" --instance "$inst" pins check
assert_contains "$DS_STDOUT$DS_STDERR" "agent_tools.example-term.linux"
