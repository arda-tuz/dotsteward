# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and settings_* variables come from the harness and helpers.sh
# Target sources: component targets from --targets-file (the generation's
# targets file or a manifest), the instance manifest mirror as the default,
# buffer targets replacing component targets of the same name without any
# field merge, per-platform paths with name-based identities, and the
# errors for unknown target names and broken targets files.
# shellcheck source=tests/engines/settings/core/helpers.sh
source "$DS_REPO_ROOT/tests/engines/settings/core/helpers.sh"

ds_use_stubs herdr

targets=$DS_TEST_ROOT/targets.json
cat >"$targets" <<'EOF'
{
  "schema_version": 1,
  "targets": {
    "comp": {
      "component": "example-app",
      "path": "~/.config/comp/settings.json",
      "format": "json",
      "create_if_missing": true,
      "create_mode": "0600",
      "backup": true,
      "reload": "herdr-server"
    },
    "shadowed": {
      "component": "example-app",
      "path": "~/.config/shadowed/component.toml",
      "format": "toml",
      "create_if_missing": true,
      "create_mode": "0600",
      "backup": true,
      "reload": {
        "command": ["herdr", "server", "reload-config"],
        "timeout": 15,
        "env": {},
        "unset_env": [],
        "require_command": null,
        "on_success": "silent",
        "on_failure": "warn"
      }
    }
  },
  "reload_hooks": {
    "herdr-server": {
      "component": "herdr",
      "command": ["herdr", "server", "reload-config"],
      "timeout": 15,
      "env": {},
      "unset_env": [],
      "require_command": "herdr",
      "on_success": "silent",
      "on_failure": "silent"
    }
  }
}
EOF

settings_buffer M <<'EOF'
schema_version = 1

[targets.shadowed]
path = "~/.config/shadowed/buffer.toml"
format = "toml"
create_if_missing = true

[[entries]]
id = "comp-key"
target = "comp"
key = ["level"]
value = 3

[[entries]]
id = "shadowed-key"
target = "shadowed"
key = ["level"]
value = 4
EOF
home=$settings_work/M/home

# Without the component target the entry names an unknown target.
assert_exit 2 lmf M status
assert_contains "$DS_STDERR" "comp"

# The component target is used as declared (path, mode, reload); the
# buffer's target of the same name replaces the component's entirely: its
# path, the default mode 0644 instead of 0600, and no reload.
assert_exit 0 lmf M --targets-file "$targets" apply
assert_eq 3 "$(json_get "$home/.config/comp/settings.json" level)"
assert_file_mode "$home/.config/comp/settings.json" 0600
assert_eq 4 "$(toml_get "$home/.config/shadowed/buffer.toml" level)"
assert_file_mode "$home/.config/shadowed/buffer.toml" 0644
[[ ! -e $home/.config/shadowed/component.toml ]] || ds_fail "the component path of a replaced target was written"
assert_call_count 1 herdr
assert_json - '.entries | map(select(.id == "comp-key"))[0].target == "comp"' \
  <<<"$(lmf M --targets-file "$targets" status --json)"

# A manifest (settings_targets and reload_hooks) works as a targets file,
# and the instance's mirror .dotsteward/manifest.<system>.json is the
# default when no targets file is given.
jq '{schema_version: 1, system: "x86_64-linux", settings_targets: .targets, reload_hooks: .reload_hooks}' \
  "$targets" >"$DS_TEST_ROOT/manifest.json"
assert_exit 0 lmf M --targets-file "$DS_TEST_ROOT/manifest.json" verify
case $(uname -s)-$(uname -m) in
  Linux-x86_64) system=x86_64-linux ;;
  Linux-aarch64) system=aarch64-linux ;;
  Darwin-arm64) system=aarch64-darwin ;;
  Darwin-x86_64) system=x86_64-darwin ;;
esac
mkdir -p "$settings_work/M/repo/.dotsteward"
cp "$DS_TEST_ROOT/manifest.json" "$settings_work/M/repo/.dotsteward/manifest.$system.json"
assert_exit 0 lmf M verify
assert_eq in-sync "$(state_of M comp-key)"
# An explicit targets file wins over the mirror.
printf '{"schema_version": 1, "targets": {}, "reload_hooks": {}}\n' >"$DS_TEST_ROOT/empty.json"
assert_exit 2 lmf M --targets-file "$DS_TEST_ROOT/empty.json" status
rm -rf "$settings_work/M/repo/.dotsteward"

# Broken targets files are errors before anything else happens.
assert_exit 2 lmf M --targets-file "$DS_TEST_ROOT/missing.json" status
assert_contains "$DS_STDERR" "missing.json"
printf 'not json\n' >"$DS_TEST_ROOT/broken.json"
assert_exit 2 lmf M --targets-file "$DS_TEST_ROOT/broken.json" status
assert_contains "$DS_STDERR" "broken.json"
printf '{"schema_version": 2, "targets": {}}\n' >"$DS_TEST_ROOT/future.json"
assert_exit 2 lmf M --targets-file "$DS_TEST_ROOT/future.json" status
jq '.targets.comp.format = "yaml"' "$targets" >"$DS_TEST_ROOT/bad-format.json"
assert_exit 2 lmf M --targets-file "$DS_TEST_ROOT/bad-format.json" status
assert_contains "$DS_STDERR" "comp"

# Per-platform paths: the platform's path is used, the identity stays the
# target name and the key on both platforms.
settings_buffer P <<'EOF'
schema_version = 1

[targets.pp]
path = { linux = "~/.config/pp/settings.json", darwin = "~/Library/Application Support/pp/settings.json" }
format = "json"
create_if_missing = true

[targets.linux-only]
path = { linux = "~/.config/lo/settings.json" }
format = "json"
create_if_missing = true

[[entries]]
id = "pp-key"
target = "pp"
key = ["level"]
value = 5
EOF
phome=$settings_work/P/home
assert_exit 0 env DOTSTEWARD_PLATFORM=linux "$DS_REPO_ROOT/cli/dotsteward" settings \
  --repo "$settings_work/P/repo" --home "$phome" --state-dir "$settings_work/P/state-linux" apply
assert_eq 5 "$(json_get "$phome/.config/pp/settings.json" level)"
[[ ! -e "$phome/Library" ]] || ds_fail "the darwin path was written on linux"
assert_exit 0 env DOTSTEWARD_PLATFORM=darwin "$DS_REPO_ROOT/cli/dotsteward" settings \
  --repo "$settings_work/P/repo" --home "$phome" --state-dir "$settings_work/P/state-darwin" apply
assert_eq 5 "$(json_get "$phome/Library/Application Support/pp/settings.json" level)"
linux_identity=$(jq -r .identity "$settings_work/P/state-linux/journal.jsonl")
darwin_identity=$(jq -r .identity "$settings_work/P/state-darwin/journal.jsonl")
assert_eq 'pp|["level"]' "$linux_identity"
assert_eq "$linux_identity" "$darwin_identity"
# A target without a path for the running platform is harmless until an
# entry uses it (the darwin apply above succeeded); then that entry's rows
# are errors on that platform, so apply refuses there.
cat >>"$settings_work/P/repo/local-maintained-files/buffer.toml" <<'EOF'

[[entries]]
id = "lo-key"
target = "linux-only"
key = ["level"]
value = 6
EOF
assert_exit 0 env DOTSTEWARD_PLATFORM=linux "$DS_REPO_ROOT/cli/dotsteward" settings \
  --repo "$settings_work/P/repo" --home "$phome" --state-dir "$settings_work/P/state-linux" apply
assert_exit 2 env DOTSTEWARD_PLATFORM=darwin "$DS_REPO_ROOT/cli/dotsteward" settings \
  --repo "$settings_work/P/repo" --home "$phome" --state-dir "$settings_work/P/state-darwin" apply
assert_contains "$DS_STDERR" "darwin"
# Paths must be home paths on every platform.
settings_buffer Q <<'EOF'
schema_version = 1

[targets.abs]
path = { linux = "/etc/abs.json", darwin = "~/abs.json" }
format = "json"
create_if_missing = true
EOF
assert_exit 2 lmf Q status
assert_contains "$DS_STDERR" "targets.abs.path"
