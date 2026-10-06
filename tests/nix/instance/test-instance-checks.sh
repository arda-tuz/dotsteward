# shellcheck shell=bash
# shellcheck disable=SC2016 # Nix expressions in single quotes
# checks.<system>.instance-static (the [gate] static scripts, run from a
# copy of the instance root) and checks.<system>.instance-contract (the
# framework's checks over the instance: each step whose command the
# framework CLI ships). The sandbox build of instance-static runs in
# checks.nix-instance.
# shellcheck source=tests/nix/instance/helpers.sh
source "$DS_REPO_ROOT/tests/nix/instance/helpers.sh"

assert_inst_eq '{"name":"instance-static","script":true,"instance":true}' \
  'let c = example.checks.x86_64-linux.instance-static; in {
    inherit (c) name;
    script = lib.hasInfix "bash ./tests/static.sh" c.buildCommand;
    instance = lib.hasInfix "DOTSTEWARD_INSTANCE=" c.buildCommand;
  }' "instance-static"
assert_inst_eq 'false' \
  'lib.hasInfix "static.sh" minimal.checks.x86_64-linux.instance-static.buildCommand' "no static scripts"

copy=$(instance_copy "$nix_instance_fixtures/example")
sed -i 's|static = \["tests/static.sh"\]|static = ["tests/static.sh", "tests/missing.sh"]|' "$copy/workstation.toml"
assert_inst_fails "(instance { root = /. + \"$copy\"; }).checks.x86_64-linux.instance-static.drvPath" \
  "dotsteward: [gate] static: tests/missing.sh does not exist in the instance"

# instance-contract runs the generic privacy scan over the instance; steps
# of commands the framework does not ship (yet) are left out.
steps=$(inst_json 'example.checks.x86_64-linux.instance-contract.passthru.steps')
json_check "$steps" 'map(select(.[0] == "scan"))' '[["scan","--tree"]]'
for command in static pins settings; do
  if [[ -f $DS_REPO_ROOT/cli/commands/$command.sh ]]; then
    json_check "$steps" "map(select(.[0] == \"$command\")) | length" 1
  else
    json_check "$steps" "map(select(.[0] == \"$command\")) | length" 0
  fi
done
assert_inst_eq 'true' \
  'lib.hasInfix "dotsteward scan --tree" example.checks.x86_64-linux.instance-contract.buildCommand' \
  "instance-contract runs the scan"
