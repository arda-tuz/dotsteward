# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# template/flake.nix: nixpkgs and home-manager at the
# revisions of the framework flake.lock, the dotsteward input at
# github:arda-tuz/dotsteward/v<VERSION> following both, the empty marker
# block `dotsteward init` fills, and outputs from lib.mkInstance.
# shellcheck source=tests/instance/template/helpers.sh
source "$DS_REPO_ROOT/tests/instance/template/helpers.sh"

flake=$tpl/flake.nix
[[ -f $flake ]] || ds_fail "template/flake.nix is missing"

# github:<owner>/<repo>/<rev> of a framework flake.lock node: the reference
# the framework flake.nix uses, so the instance locks the same tree.
github_reference() {
  jq -er '.original | select(.type == "github") | "github:\(.owner)/\(.repo)/\(.ref // .rev)"' <<<"$1"
}
nixpkgs_node=$(lock_node nixpkgs)
home_manager_node=$(lock_node home-manager)
nixpkgs_ref=$(github_reference "$nixpkgs_node")
home_manager_ref=$(github_reference "$home_manager_node")
# The framework pins revisions, not branches.
assert_eq "github:NixOS/nixpkgs/$(jq -r .locked.rev <<<"$nixpkgs_node")" "$nixpkgs_ref" "framework nixpkgs pin"
assert_eq "github:nix-community/home-manager/$(jq -r .locked.rev <<<"$home_manager_node")" \
  "$home_manager_ref" "framework home-manager pin"

version=$(<"$DS_REPO_ROOT/VERSION")
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || ds_fail "unexpected VERSION [$version]"

# The inputs, exactly.
inputs=$(template_flake_inputs)
expected=$(jq -n --arg nixpkgs "$nixpkgs_ref" --arg hm "$home_manager_ref" \
  --arg ds "github:arda-tuz/dotsteward/v$version" '{
    nixpkgs: { url: $nixpkgs },
    "home-manager": { url: $hm, inputs: { nixpkgs: { follows: "nixpkgs" } } },
    dotsteward: { url: $ds, inputs: { nixpkgs: { follows: "nixpkgs" }, "home-manager": { follows: "home-manager" } } }
  }')
assert_eq "$(jq -S . <<<"$expected")" "$(jq -S . <<<"$inputs")" "template flake inputs"

# The description and the outputs line of the template flake.
assert_eq '"dotsteward instance"' "$(inst_json "(import (repoRoot + \"/template/flake.nix\")).description")" \
  "description"
grep -qxF '  outputs = inputs: inputs.dotsteward.lib.mkInstance { inherit inputs; };' "$flake" ||
  ds_fail "template/flake.nix lacks the mkInstance outputs line"
assert_eq '"lambda"' "$(inst_json "builtins.typeOf (import (repoRoot + \"/template/flake.nix\")).outputs")" \
  "outputs is a function"

# The marker block: each marker exactly once, begin before end, nothing
# between them (init writes the component inputs there), both inside the
# inputs set.
begin=$(grep -n -xE '[[:space:]]*# dotsteward:inputs:begin' "$flake" | cut -d: -f1)
end=$(grep -n -xE '[[:space:]]*# dotsteward:inputs:end' "$flake" | cut -d: -f1)
[[ $begin =~ ^[0-9]+$ ]] || ds_fail "template/flake.nix needs exactly one '# dotsteward:inputs:begin' line, found [$begin]"
[[ $end =~ ^[0-9]+$ ]] || ds_fail "template/flake.nix needs exactly one '# dotsteward:inputs:end' line, found [$end]"
assert_eq "$((begin + 1))" "$end" "the marker block is empty"
assert_eq "$(sed -n "${begin}p" "$flake" | sed 's/#.*//')" "$(sed -n "${end}p" "$flake" | sed 's/#.*//')" \
  "both markers have the same indentation"
inputs_open=$(grep -n -xE '[[:space:]]*inputs = \{' "$flake" | head -n 1 | cut -d: -f1)
[[ -n $inputs_open && $inputs_open -lt $begin ]] || ds_fail "the marker block is not inside the inputs set"
# The dotsteward input is declared before the markers, so init only ever
# appends below the framework inputs.
dotsteward_line=$(grep -n -E '^[[:space:]]*dotsteward = \{' "$flake" | cut -d: -f1)
[[ -n $dotsteward_line && $dotsteward_line -lt $begin ]] || ds_fail "the dotsteward input is not above the markers"

# The lock nix flake lock would write for the template: the framework's
# nixpkgs and home-manager nodes, dotsteward following both.
inst=$DS_TEST_ROOT/lock
mkdir -p "$inst"
cp "$flake" "$inst/flake.nix"
write_instance_lock "$inst"
assert_json "$inst/flake.lock" '.version == 7 and .root == "root"
  and (.nodes.root.inputs | keys) == ["dotsteward", "home-manager", "nixpkgs"]'
assert_eq "$(jq -S . <<<"$nixpkgs_node")" "$(jq -S .nodes.nixpkgs "$inst/flake.lock")" "nixpkgs node"
assert_eq "$(jq -S . <<<"$home_manager_node")" "$(jq -S '.nodes["home-manager"]' "$inst/flake.lock")" \
  "home-manager node"
assert_eq "{\"home-manager\":[\"home-manager\"],\"nixpkgs\":[\"nixpkgs\"]}" \
  "$(jq -cS .nodes.dotsteward.inputs "$inst/flake.lock")" "dotsteward follows"
assert_eq "{\"owner\":\"arda-tuz\",\"ref\":\"v$version\",\"repo\":\"dotsteward\",\"type\":\"github\"}" \
  "$(jq -cS .nodes.dotsteward.original "$inst/flake.lock")" "dotsteward original"

# Another reference shape is refused, not misread.
sed -i 's|github:arda-tuz/dotsteward/v[0-9.]*|git+file:///tmp/dotsteward|' "$inst/flake.nix"
assert_exit 1 write_instance_lock "$inst"
assert_contains "$DS_STDERR" "is not github:<owner>/<repo>/<tag>"
