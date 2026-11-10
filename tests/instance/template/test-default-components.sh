# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# A catalog component enabled by default: apt-policy keeps the "no removals" protection of
# the gated classes (T2-a) on every instance with a Linux system, without a line in
# workstation.toml, as the apt engine did before the component took the drop-in over. Both
# configuration readers agree; enable = false is the one way out, and an instance without a
# Linux system does not get it.
# shellcheck source=tests/instance/template/helpers.sh
source "$DS_REPO_ROOT/tests/instance/template/helpers.sh"

# enabled TOML: the enabled components of TOML, from both readers (which must agree).
enabled() {
  local file=$DS_TEST_ROOT/case.toml cli nix
  printf '%s\n' "$1" >"$file"
  cli=$(PYTHONPATH=$DS_REPO_ROOT/cli/python PYTHONDONTWRITEBYTECODE=1 \
    python3 -s -P -m dotsteward_cli.config --file "$file" resolve)
  nix=$(inst_json "dsLib.config.resolve { catalog = builtins.attrNames dsLib.catalog; }
    (builtins.fromTOML (builtins.readFile /. + \"$file\"))")
  assert_eq "$(jq -S . <<<"$nix")" "$(jq -S . <<<"$cli")" "both readers agree"
  jq -c '[.components | to_entries[] | select(.key != "order" and .value.enable) | .key]' <<<"$cli"
}

base='schema_version = 1
[identity]
username = "user"
[instance]
remote = "git@github.com:user/workstation.git"
[profiles]
names = ["workstation"]'

assert_eq '["apt-policy"]' "$(enabled "$base")" "Linux by default"
assert_eq '["apt-policy"]' "$(enabled "$base
[nix]
systems = [\"x86_64-linux\", \"aarch64-darwin\"]")" "Linux and darwin"
assert_eq '[]' "$(enabled "$base
[nix]
systems = [\"aarch64-darwin\"]")" "no Linux system"
assert_eq '[]' "$(enabled "$base
[components.apt-policy]
enable = false")" "the opt-out"
assert_eq '["apt-policy"]' "$(enabled "$base
[components.apt-policy]
tags = [\"nvidia\"]")" "a table without enable keeps the default"

# Ubuntu 22.04 takes the fast route only once its install end to end runs in CI: the template
# shows the fast path, commented out.
platform22=$(python3 -c 'import json, sys, tomllib; print(json.dumps(tomllib.load(open(sys.argv[1], "rb"))))' \
  "$tpl/platforms/ubuntu-22.04.toml")
assert_json - 'has("fast_path") | not' "no active fast path for 22.04" <<<"$platform22"
assert_contains "$(<"$tpl/platforms/ubuntu-22.04.toml")" '# [fast_path]'
