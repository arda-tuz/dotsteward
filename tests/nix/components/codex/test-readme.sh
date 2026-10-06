# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The workstation.toml examples of the codex component README: every toml
# block parses with both readers of workstation.toml (Nix builtins.fromTOML,
# used by lib/config.nix, and Python tomllib, used by the CLI) to the same
# value, and the plugins example, used verbatim as the [components.codex]
# section of an instance, reaches lib.mkInstance and the CLI as the plugin
# list it documents.
# shellcheck source=tests/nix/components/codex/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/codex/helpers.sh"

readme=$DS_REPO_ROOT/modules/components/codex/README.md
blocks=$DS_TEST_ROOT/readme-blocks
mkdir -p "$blocks"

# Every ```toml fenced block of the README, one file each.
awk -v dir="$blocks" '
  /^```toml[[:space:]]*$/ { n++; file = sprintf("%s/%02d.toml", dir, n); inside = 1; next }
  inside && /^```[[:space:]]*$/ { inside = 0; close(file); next }
  inside { print > file }
' "$readme"
mapfile -t toml_files < <(find "$blocks" -name '*.toml' | LC_ALL=C sort)
((${#toml_files[@]} >= 2)) || ds_fail "expected at least two toml blocks in $readme, found ${#toml_files[@]}"

# tomllib_json FILE: the value of FILE as Python tomllib reads it.
tomllib_json() {
  python3 -I -c 'import json, sys, tomllib
try:
    with open(sys.argv[1], "rb") as handle:
        print(json.dumps(tomllib.load(handle)))
except tomllib.TOMLDecodeError as error:
    sys.exit(f"tomllib: {error}")' "$1" | jq -cS .
}

plugins_block=""
for file in "${toml_files[@]}"; do
  python_value=$(tomllib_json "$file") ||
    ds_fail "README toml block $(basename "$file") is not valid TOML for tomllib:
$(<"$file")"
  nix_instance_eval "builtins.fromTOML (builtins.readFile (/. + \"$file\"))" ||
    ds_fail "README toml block $(basename "$file") is not valid TOML for builtins.fromTOML: $DS_STDERR
$(<"$file")"
  assert_eq "$python_value" "$(jq -cS . <<<"$DS_STDOUT")" "both readers agree on README toml block $(basename "$file")"
  if jq -e '.components.codex.options.plugins' <<<"$python_value" >/dev/null; then
    plugins_block=$file
  fi
done
[[ -n $plugins_block ]] || ds_fail "no README toml block sets components.codex.options.plugins"

expected_plugins=$(jq -cS . <<'EOF'
[
  {
    "spec": "example-plugin@example-market",
    "minimumAt": "agent_tools.example-plugin.minimum_version",
    "requiredSkillDirectories": ["alpha", "beta"]
  }
]
EOF
)

# --- The plugins example as an instance's [components.codex] section ------------------

# codex_instance ends workstation.toml with the [components.codex] section;
# replace that section with the README block, unchanged.
inst=$(codex_instance readme)
awk '/^\[components\.codex\]$/ { exit } { print }' "$inst/workstation.toml" >"$inst/workstation.toml.new"
cat "$plugins_block" >>"$inst/workstation.toml.new"
mv -- "$inst/workstation.toml.new" "$inst/workstation.toml"
codex_lock_set "$inst" agent_tools.example-plugin '{"minimum_version": "1.2.0"}'

# lib.mkInstance: the documented plugin list and the plugins hook.
manifest=$(inst_json "storeless (homeOf ($(codex_expr "$inst")) \"x86_64-linux\" \"workstation\").dotsteward.manifest")
json_check "$manifest" '.components[] | select(.name == "codex") | .options.plugins' "$expected_plugins"
json_check "$manifest" '[.hooks.agents_post[] | select(.component == "codex") | .name]' '["plugins"]'

# The CLI reads the same instance; its plugins hook (agents check) sees the
# documented plugin and reports it missing without installing anything.
codex_hermetic_path
ds_use_stubs codex
# The example keeps the default method (official-binary): the binary on PATH
# is the locked release.
ds_stub_set codex version "codex-cli $(jq -r .agent_tools.codex.linux.version "$inst/versions.lock.json")"
codex_mirror "$inst"
mkdir -p "$HOME/.codex/skills" "$HOME/.agents/skills"
assert_exit 1 codex_cli "$inst" agents check --profile workstation
assert_contains "$DS_STDERR" "codex plugin example-plugin@example-market is not installed and enabled"
assert_call_count 0 codex 'plugin add*'
