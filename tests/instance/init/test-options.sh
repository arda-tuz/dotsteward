# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs and literal texts are single-quoted on purpose
# The workstation.toml init writes: identity,
# instance, systems, the two profiles (the first adopts and is default and
# check, the second is fresh and bootstraps), the components in catalog
# order with their methods, the contribution mode and unfree packages. It is
# the template's file edited with tomlkit: the header comment is replaced
# (the template marker goes with it), every other comment stays, and the
# configuration reader accepts it.
# shellcheck source=tests/instance/init/helpers.sh
source "$DS_REPO_ROOT/tests/instance/init/helpers.sh"

init_use_nix
mkdir -p "$DS_TEST_ROOT/instances"

header='# The instance configuration (schema 1), written by `dotsteward init`. The
# framework documents every key in docs/workstation-toml.md and
# schema/workstation.schema.json of its repository.'

# assert_template_comments FILE: the comments of the template below its
# header comment are in FILE, in order.
assert_template_comments() {
  local expected actual
  expected=$(awk 'body && /^#/ { print } /^[^#]/ { body = 1 }' "$tpl/workstation.toml")
  actual=$(awk 'body && /^#/ { print } /^[^#]/ { body = 1 }' "$1")
  [[ -n $expected ]] || ds_fail "the template has no comments below its header"
  assert_eq "$expected" "$actual" "the template comments in $1"
}

# config_errors FILE: the configuration reader's messages for FILE.
config_errors() {
  PYTHONPATH=$DS_REPO_ROOT/cli/python python3 -m dotsteward_cli.config --file "$1" errors
}

# --- every option, both systems ------------------------------------------------------------

dir=$DS_TEST_ROOT/instances/box
# shellcheck disable=SC2088 # init receives the literal ~/ path
init_run 0 --dir "$dir" --remote "git@example.invalid:alice/box.git" --username dotsteward-test --home "$HOME" \
  --name desk --checkout "~/src/desk" --components vscode,codex,shell \
  --method codex=official-binary --method-platform vscode=linux:deb,darwin:app-archive \
  --systems x86_64-linux,aarch64-darwin --profiles dev,new --allow-unfree --contribute owner
file=$dir/workstation.toml
assert_eq "$header" "$(head -n 3 "$file")" "the header"
assert_template_comments "$file"
assert_eq "[]" "$(config_errors "$file")" "the configuration reader accepts it"
assert_jq - '. == {
  schema_version: 1,
  identity: { username: "dotsteward-test", home: $home },
  instance: { name: "desk", remote: "git@example.invalid:alice/box.git", checkout: "~/src/desk" },
  nix: { systems: ["x86_64-linux", "aarch64-darwin"], allow_unfree: true, state_version: "26.05" },
  profiles: {
    names: ["dev", "new"], default: "dev", check: "dev", bootstrap: "new",
    dev: { mode: "adopt" }, new: { mode: "fresh" }
  },
  components: {
    order: ["shell", "codex", "vscode"],
    shell: { enable: true },
    codex: { enable: true, method: "official-binary" },
    vscode: { enable: true, method_by_platform: { linux: "deb", darwin: "app-archive" } }
  },
  upstream: { contribute: "owner" }
}' --arg home "$HOME" <<<"$(toml_json "$file")"
# The tables as init writes them, after the template's comment on
# components.
grep -qxF 'method_by_platform = { linux = "deb", darwin = "app-archive" }' "$file" ||
  ds_fail "method_by_platform is not an inline table: $(<"$file")"
assert_eq '# your own components in components/<name>/.
[components]
order = ["shell", "codex", "vscode"]' "$(grep -B1 -A1 -xF '[components]' "$file")" "the components table follows the comment"
assert_eq 'contribute = "owner"' "$(tail -n 1 "$file")" "upstream ends the file"
# Both systems have their mirrors.
for mirror in manifest.x86_64-linux.json manifest.aarch64-darwin.json stage0.linux.env stage0.darwin.env; do
  [[ -f $dir/.dotsteward/$mirror ]] || ds_fail "the mirror .dotsteward/$mirror is missing"
done
assert_jq "$dir/.dotsteward/manifest.aarch64-darwin.json" \
  '[.components[] | {name, method}] == [{name: "shell", method: "nix"}, {name: "codex", method: "official-binary"}, {name: "vscode", method: "app-archive"}]'
instance_contract "$dir" aarch64-darwin

# --- the defaults ----------------------------------------------------------------------------

dir=$DS_TEST_ROOT/instances/plain
init_run 0 --dir "$dir" --remote "$init_remote"
file=$dir/workstation.toml
assert_eq "$header" "$(head -n 3 "$file")" "the header"
assert_template_comments "$file"
assert_eq "[]" "$(config_errors "$file")" "the configuration reader accepts it"
assert_jq - '.profiles == {
  names: ["workstation", "fresh"], default: "workstation", check: "workstation", bootstrap: "fresh",
  workstation: { mode: "adopt" }, fresh: { mode: "fresh" }
} and .upstream == { contribute: "fork" } and .nix.allow_unfree == false and (has("components") | not)' \
  <<<"$(toml_json "$file")"
# Without components the template's comment on them ends the file.
assert_eq "$(tail -n 3 "$tpl/workstation.toml")" "$(tail -n 3 "$file")" "the components comment ends the file"
# The template's tables keep their layout: only the values init sets differ.
assert_eq "$(sed -n '/^\[profiles\]/,/^mode = "fresh"/p' "$tpl/workstation.toml")" \
  "$(sed -n '/^\[profiles\]/,/^mode = "fresh"/p' "$file")" "the profiles tables"

# --- the identity of a Mac ---------------------------------------------------------------------

# On darwin the home is the darwin check home; the default /Users/<user>
# would not be written.
dir=$DS_TEST_ROOT/instances/mac
assert_exit 1 env DOTSTEWARD_PLATFORM=darwin DS_INIT_NIX_FAIL='eval *' "$DS_CLI" init --dir "$dir" \
  --remote "$init_remote" --systems aarch64-darwin
assert_jq - '.identity == { username: "dotsteward-test", darwin_home: $home } and .nix.systems == ["aarch64-darwin"]' \
  --arg home "$HOME" <<<"$(toml_json "$(init_staged)/workstation.toml")"
# A user name only darwin accepts.
assert_exit 1 env DOTSTEWARD_PLATFORM=darwin DS_INIT_NIX_FAIL='eval *' "$DS_CLI" init --dir "$dir" \
  --remote "$init_remote" --systems aarch64-darwin --username Alice.Smith
assert_contains "$DS_STDERR" "dotsteward sync --nix failed"
assert_jq - '.identity.username == "Alice.Smith"' <<<"$(toml_json "$(init_staged)/workstation.toml")"
assert_exit 1 "$DS_CLI" init --dir "$dir" --remote "$init_remote" --username Alice.Smith
assert_contains "$DS_STDERR" "unsafe user name: Linux user names must match"

# --- no git ------------------------------------------------------------------------------------

dir=$DS_TEST_ROOT/instances/nogit
init_run 0 --dir "$dir" --remote "$init_remote" --no-git --components herdr
[[ ! -e $dir/.git ]] || ds_fail "--no-git initialized a repository"
assert_not_contains "$DS_STDOUT" "Committed"
assert_contains "$DS_STDOUT" "1. Commit the instance:"
# No git identity is needed without git.
printf '[init]\ndefaultBranch = main\n' >"$DS_TEST_ROOT/gitconfig-anonymous"
rm -rf "$dir"
assert_exit 0 env GIT_CONFIG_GLOBAL="$DS_TEST_ROOT/gitconfig-anonymous" "$DS_CLI" init --dir "$dir" \
  --remote "$init_remote" --no-git
[[ -f $dir/flake.lock ]] || ds_fail "init --no-git did not write the instance"
