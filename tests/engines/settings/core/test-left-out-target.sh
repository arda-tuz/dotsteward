# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and settings_* variables come from the harness and helpers.sh
# An entry of a target whose component is not active on this machine waits: no error, nothing
# written, kept in the buffer. A target nobody declares is still an error. The generation says it
# with "active": false in its targets file, E2E with --inactive-components.
# shellcheck source=tests/engines/settings/core/helpers.sh
source "$DS_REPO_ROOT/tests/engines/settings/core/helpers.sh"

settings_buffer A <<'TOML'
schema_version = 1

[[entries]]
id = "left-out"
target = "sleeping"
key = ["theme"]
value = "dark"

[[entries]]
id = "here"
target = "awake"
key = ["size"]
value = 12
TOML
targets=$settings_work/targets.json
home=$settings_work/A/home
mkdir -p "$home/.sleeping" "$home/.awake"
printf '{"theme": "light"}\n' >"$home/.sleeping/config.json"
printf '{"size": 10}\n' >"$home/.awake/config.json"
write_targets() {
  jq -n --argjson sleeping "$1" '{schema_version: 1, reload_hooks: {}, targets: {
    sleeping: ({component: "a", path: "~/.sleeping/config.json", format: "json", backup: true,
      create_if_missing: false, create_mode: "0644", reload: null} + $sleeping),
    awake: {component: "b", path: "~/.awake/config.json", format: "json", backup: true,
      create_if_missing: false, create_mode: "0644", reload: null}}}' >"$targets"
}

# The generation: the target is there, and not active.
write_targets '{"active": false}'
assert_exit 0 lmf A --targets-file "$targets" status --json
assert_not_contains "$DS_STDOUT" 'left-out'
assert_contains "$DS_STDOUT" '"here"'
assert_exit 0 lmf A --targets-file "$targets" apply
assert_contains "$(<"$home/.sleeping/config.json")" 'light'
assert_contains "$(<"$home/.awake/config.json")" '12'
assert_exit 0 lmf A --targets-file "$targets" flush
assert_eq '"dark"' "$(buffer_get A left-out)"
buffer_has "$settings_work/A/repo" left-out || ds_fail "a save dropped the entry that waits"

# A component that comes back: the entry takes effect.
write_targets '{"active": true}'
assert_exit 0 lmf A --targets-file "$targets" apply
assert_contains "$(<"$home/.sleeping/config.json")" 'dark'

# The same through --inactive-components, for a targets file that says nothing: a manifest.
write_targets '{}'
printf '{"theme": "light"}\n' >"$home/.sleeping/config.json"
assert_exit 0 lmf A --targets-file "$targets" --inactive-components '["a"]' status --json
assert_not_contains "$DS_STDOUT" 'left-out'
assert_exit 0 lmf A --targets-file "$targets" --inactive-components '["other"]' status --json
assert_contains "$DS_STDOUT" 'left-out'

# Tracking the same id again stays refused while the entry waits.
write_targets '{"active": false}'
assert_exit 2 lmf A --targets-file "$targets" track --id left-out --target awake --key size
# A target nobody declares is what it always was.
jq 'del(.targets.sleeping)' "$targets" >"$targets.new"
mv -- "$targets.new" "$targets"
assert_exit 2 lmf A --targets-file "$targets" status
assert_contains "$DS_STDERR" "unknown target 'sleeping'"
