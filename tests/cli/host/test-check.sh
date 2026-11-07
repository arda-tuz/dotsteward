# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# `dotsteward host check` holds the tree to the rules of the machines: every host file is
# valid and named like a machine, every machines list is not empty and names machines of
# hosts/. A tree that names no machine passes.
# shellcheck source=tests/cli/host/helpers.sh
source "$DS_REPO_ROOT/tests/cli/host/helpers.sh"

# problems: what `host check` reports, which `dotsteward static` reports too, so the gate
# refuses a commit that would drop a skill from every machine without a word.
problems() {
  assert_exit 1 run_host check
  printf '%s\n' "$DS_STDERR"
  assert_exit 1 "$agents_fw/cli/dotsteward" --instance "$agents_inst" static --only hosts </dev/null
  assert_contains "$DS_STDERR" "static checks failed"
  printf '%s\n' "$DS_STDERR"
}

assert_exit 0 run_host check
assert_contains "$DS_STDOUT" "0 registered"
assert_exit 0 "$agents_fw/cli/dotsteward" --instance "$agents_inst" static --only hosts </dev/null

lock_add alpha
lock_add beta
write_host laptop 'system = "x86_64-linux"
profile = "workstation"'
set_machines alpha '["laptop"]'
assert_exit 0 run_host check
assert_contains "$DS_STDOUT" "1 registered"

# machines: empty, an unknown name, a repeat.
set_machines alpha '[]'
assert_contains "$(problems)" "skill alpha: machines must be a non-empty list"
set_machines alpha '"laptop"'
assert_contains "$(problems)" "skill alpha: machines must be a non-empty list"
set_machines alpha '["laptop", "nobody"]'
assert_contains "$(problems)" "skill alpha: machines names nobody, which has no hosts/nobody.toml"
set_machines alpha '["laptop", "laptop"]'
assert_contains "$(problems)" "skill alpha: machines lists a machine more than once"
set_machines alpha '["laptop"]'

# machines with a deployment Home Manager makes for every machine.
lock_edit '(.skills[] | select(.name == "alpha")).deployment = "home-manager"'
assert_contains "$(problems)" "skill alpha: machines needs the copy deployment"
lock_edit '(.skills[] | select(.name == "alpha")) |= del(.deployment)'

# own plugins and plugin tables.
lock_edit '.own_plugins = [{ name: "own-plugin", machines: ["nobody"] }]'
assert_contains "$(problems)" "plugin own-plugin: machines names nobody"
lock_edit 'del(.own_plugins)'
{
  printf '\n[components.example]\nenable = true\n'
  printf '[[components.example.options.plugins]]\nspec = "scoped@market"\nmachines = ["nobody"]\n'
} >>"$agents_inst/workstation.toml"
assert_contains "$(problems)" "plugin scoped@market: machines names nobody"
sed -i 's/machines = \["nobody"\]/machines = ["laptop"]/' "$agents_inst/workstation.toml"
assert_exit 0 run_host check

# The host files.
write_host desktop 'nonsense = 1'
assert_contains "$(problems)" "hosts/desktop.toml: unknown key nonsense"
write_host desktop 'profile = "nonsense"'
assert_contains "$(problems)" "hosts/desktop.toml: profile nonsense is not in profiles.names"
write_host desktop 'system = "riscv64-linux"'
assert_contains "$(problems)" "hosts/desktop.toml: system riscv64-linux is not in nix.systems"
write_host desktop 'tags = ["machine:reserved"]'
assert_contains "$(problems)" 'hosts/desktop.toml: tags[0]:'
write_host desktop 'this is not toml'
assert_contains "$(problems)" "hosts/desktop.toml: invalid TOML"
rm -- "$agents_inst/hosts/desktop.toml"
printf 'schema_version = 1\n' >"$agents_inst/hosts/Not_A_Name.toml"
assert_contains "$(problems)" "hosts/Not_A_Name.toml: expected hosts/<name>.toml"
rm -- "$agents_inst/hosts/Not_A_Name.toml"
printf 'stray\n' >"$agents_inst/hosts/README.md"
assert_contains "$(problems)" "hosts/README.md: expected hosts/<name>.toml"
rm -- "$agents_inst/hosts/README.md"
assert_exit 0 run_host check
assert_exit 0 "$agents_fw/cli/dotsteward" --instance "$agents_inst" static --only hosts </dev/null
