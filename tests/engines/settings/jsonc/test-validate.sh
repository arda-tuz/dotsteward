# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and settings_* variables come from the harness and helpers.sh
# `dotsteward settings validate`: the static lint of a buffer. A valid buffer
# (the JSONC fixture and the core engine fixture) passes without touching
# any file: no state directory, nothing in the home, the buffer unchanged.
# Each rule has one mutation that fails with exit 2 and a message naming the
# problem: schema, allowed keys, '~/' paths (per platform too), formats and
# modes, ids, secret and home guards (the home of --home), id and identity
# uniqueness, nested keys, unknown targets, the files/ set against the file
# entries, the executable bit against the mode, and inline reload tables.
# Every problem is reported in one run. Component targets come from
# --targets-file.
# shellcheck source=tests/engines/settings/core/helpers.sh
source "$DS_REPO_ROOT/tests/engines/settings/core/helpers.sh"

jsonc_fixtures=$DS_REPO_ROOT/tests/engines/settings/jsonc/fixtures

# case_repo NAME [BUFFER_DIR]: a fresh repository for machine NAME; prints
# the path of its buffer.toml.
case_repo() {
  settings_repo "$settings_work/$1/repo" "${2:-$jsonc_fixtures/buffer}"
  mkdir -p "$settings_work/$1/home"
  printf '%s\n' "$settings_work/$1/repo/local-maintained-files/buffer.toml"
}

# invalid NAME NEEDLE...: validate of machine NAME exits 2 and its errors
# contain every NEEDLE.
invalid() {
  local name=$1 needle
  shift
  assert_exit 2 lmf "$name" validate
  for needle in "$@"; do
    assert_contains "$DS_STDERR" "$needle" "$name"
  done
}

# Valid buffers pass and nothing is written.
for fixture in "$jsonc_fixtures/buffer" "$settings_fixtures/buffer"; do
  name=valid-$(basename "$(dirname "$(dirname "$fixture")")")
  buffer=$(case_repo "$name" "$fixture")
  # The core fixture keeps its 0755 file entry's source without the
  # executable bit (the engine never reads it); validate requires it.
  if [[ -f $settings_work/$name/repo/local-maintained-files/files/alpha-status.sh ]]; then
    chmod 0755 "$settings_work/$name/repo/local-maintained-files/files/alpha-status.sh"
  fi
  before=$(sha "$buffer")
  changes=$(git -C "$settings_work/$name/repo" status --porcelain)
  assert_exit 0 lmf "$name" validate
  assert_contains "$DS_STDOUT" "is valid"
  assert_eq "" "$DS_STDERR" "$name"
  assert_eq "$before" "$(sha "$buffer")"
  [[ ! -e $settings_work/$name/state ]] || ds_fail "$name: validate created the state directory"
  [[ -z $(find "$settings_work/$name/home" -mindepth 1) ]] || ds_fail "$name: validate wrote to the home"
  assert_eq "$changes" "$(git -C "$settings_work/$name/repo" status --porcelain)" "$name: validate changed the repository"
done
assert_contains "$DS_STDOUT" "11 entries"

# Buffer-level rules.
buffer=$(case_repo schema)
set_line "$buffer" 'schema_version = 1' 'schema_version = 2'
invalid schema "schema_version must be 1"

buffer=$(case_repo top-level)
set_line "$buffer" 'schema_version = 1' $'schema_version = 1\nextra = true'
invalid top-level "unknown top-level fields ['extra']"

buffer=$(case_repo not-toml)
printf 'not = = toml\n' >>"$buffer"
invalid not-toml "cannot parse"

# Target rules.
buffer=$(case_repo target-key)
set_line "$buffer" 'format = "jsonc"' $'format = "jsonc"\ncolour = "red"'
invalid target-key "targets.delta: unknown fields ['colour']"

buffer=$(case_repo target-path)
set_line "$buffer" 'path = "~/.config/delta/settings.json"' 'path = "/etc/delta.json"'
invalid target-path "targets.delta.path must start with '~/'"

buffer=$(case_repo platform-path)
set_line "$buffer" 'path = "~/.config/delta/settings.json"' \
  'path = { linux = "~/.config/delta/settings.json", darwin = "/Library/delta.json" }'
invalid platform-path "targets.delta.path.darwin must start with '~/'"

buffer=$(case_repo target-format)
set_line "$buffer" 'format = "jsonc"' 'format = "yaml"'
invalid target-format "targets.delta.format must be one of json, toml, jsonc"

buffer=$(case_repo create-mode)
set_line "$buffer" 'create_mode = "0644"' 'create_mode = "644"'
invalid create-mode "targets.delta.create_mode must look like '0644'"

buffer=$(case_repo inline-reload)
set_line "$buffer" 'format = "jsonc"' $'format = "jsonc"\nreload = { command = [] }'
invalid inline-reload "targets.delta.reload.command must be a non-empty list"

# Entry rules (appended entries).
append_entry() {
  local name=$1
  buffer=$(case_repo "$name")
  printf '\n' >>"$buffer"
  cat >>"$buffer"
}

append_entry entry-key <<'EOF'
[[entries]]
id = "delta-colour"
target = "delta"
key = ["colour"]
value = "red"
colour = "unknown"
EOF
invalid entry-key "delta-colour: unknown fields ['colour']"

append_entry entry-id <<'EOF'
[[entries]]
id = "-bad"
target = "delta"
key = ["x"]
value = 1
EOF
invalid entry-id "invalid entry id: '-bad'"

append_entry unknown-target <<'EOF'
[[entries]]
id = "nowhere-x"
target = "nowhere"
key = ["x"]
value = 1
EOF
invalid unknown-target "nowhere-x: unknown target 'nowhere'"

append_entry value-and-absent <<'EOF'
[[entries]]
id = "delta-both"
target = "delta"
key = ["x"]
value = 1
absent = true
EOF
invalid value-and-absent "delta-both: exactly one of value or absent = true is required"

append_entry secret-segment <<'EOF'
[[entries]]
id = "delta-auth"
target = "delta"
key = ["auth", "apiKey"]
value = "placeholder"
EOF
invalid secret-segment "delta-auth: a key that may hold a secret cannot be tracked"

append_entry secret-value <<'EOF'
[[entries]]
id = "delta-session"
target = "delta"
key = ["session"]

[entries.value]
refresh_token = "placeholder"
EOF
invalid secret-value "delta-session.refresh_token: a key that may hold a secret cannot be tracked"

home=$settings_work/home-value/home
append_entry home-value <<EOF
[[entries]]
id = "delta-notes"
target = "delta"
key = ["notes.folder"]
value = "$home/notes"
EOF
invalid home-value "delta-notes: the value contains the absolute home directory"

append_entry duplicate-id <<'EOF'
[[entries]]
id = "delta-size"
target = "delta"
key = ["editor.tabSize"]
value = 2
EOF
invalid duplicate-id "duplicate entry id: delta-size"

append_entry duplicate-identity <<'EOF'
[[entries]]
id = "delta-size-again"
target = "delta"
key = ["editor.fontSize"]
value = 16
EOF
invalid duplicate-identity "the same target and key twice: editor.fontSize"

append_entry nested <<'EOF'
[[entries]]
id = "delta-git"
target = "delta"
key = ["files.exclude", "**/.git"]
value = true
EOF
invalid nested "delta-git lies inside delta-exclude"

append_entry file-mode <<'EOF'
[[entries]]
id = "delta-tasks"
kind = "file"
path = "~/.config/delta/tasks.json"
source = "delta-tasks.json"
mode = "755"
EOF
invalid file-mode "delta-tasks: mode must look like '0755'"

append_entry file-path <<'EOF'
[[entries]]
id = "delta-tasks"
kind = "file"
path = "/etc/delta/tasks.json"
source = "delta-tasks.json"
EOF
invalid file-path "delta-tasks: path must start with '~/'"

# The files/ directory against the file entries.
files_of() {
  printf '%s\n' "$settings_work/$1/repo/local-maintained-files/files"
}

case_repo stray >/dev/null
printf 'left over\n' >"$(files_of stray)/stray.txt"
invalid stray "local-maintained-files/files/stray.txt is not the source of any file entry"

case_repo stray-dir >/dev/null
mkdir "$(files_of stray-dir)/nested"
invalid stray-dir "local-maintained-files/files/nested is not a regular file"

case_repo stray-link >/dev/null
ln -s delta-keybindings.json "$(files_of stray-link)/link.json"
invalid stray-link "local-maintained-files/files/link.json is not a regular file"

case_repo missing-source >/dev/null
rm "$(files_of missing-source)/delta-keybindings.json"
invalid missing-source "delta-keys: repository source missing: local-maintained-files/files/delta-keybindings.json"

buffer=$(case_repo absent-with-source)
set_line "$buffer" 'mode = "0644"' $'mode = "0644"\nabsent = true'
invalid absent-with-source "local-maintained-files/files/delta-keybindings.json is not the source of any file entry"
rm "$(files_of absent-with-source)/delta-keybindings.json"
assert_exit 0 lmf absent-with-source validate

case_repo exec-bit >/dev/null
chmod 0755 "$(files_of exec-bit)/delta-keybindings.json"
invalid exec-bit "delta-keys: mode 0644 disagrees with the executable bit of local-maintained-files/files/delta-keybindings.json"

buffer=$(case_repo exec-mode)
set_line "$buffer" 'mode = "0644"' 'mode = "0755"'
invalid exec-mode "delta-keys: mode 0755 disagrees with the executable bit"
chmod 0755 "$(files_of exec-mode)/delta-keybindings.json"
assert_exit 0 lmf exec-mode validate

case_repo home-content >/dev/null
printf '// %s/notes\n[]\n' "$settings_work/home-content/home" >>"$(files_of home-content)/delta-keybindings.json"
invalid home-content "delta-keys: the file content contains the absolute home directory"

# Every problem is reported in one run, with a count.
buffer=$(case_repo several)
set_line "$buffer" 'schema_version = 1' 'schema_version = 2'
set_line "$buffer" 'format = "jsonc"' 'format = "yaml"'
printf 'left over\n' >"$(files_of several)/stray.txt"
invalid several "schema_version must be 1" "targets.delta.format must be one of" "stray.txt" "3 problems"
# An entry on a broken target is still checked.
buffer=$(case_repo broken-target)
set_line "$buffer" 'format = "jsonc"' 'format = "yaml"'
set_line "$buffer" 'key = \["editor.fontSize"\]' 'key = ["auth", "password"]'
invalid broken-target "targets.delta.format" "delta-size: a key that may hold a secret" "2 problems"
assert_not_contains "$DS_STDERR" "unknown target"

# Component targets: an entry on a target of the targets file is valid, and
# unknown without it; a buffer target of the same name replaces it.
targets=$DS_TEST_ROOT/targets.json
cat >"$targets" <<'EOF'
{
  "schema_version": 1,
  "targets": {
    "comp": {
      "component": "example-app",
      "path": "~/.config/comp/settings.json",
      "format": "jsonc",
      "create_if_missing": true,
      "create_mode": "0600",
      "backup": true,
      "reload": null
    }
  },
  "reload_hooks": {}
}
EOF
append_entry component <<'EOF'
[[entries]]
id = "comp-size"
target = "comp"
key = ["editor.fontSize"]
value = 12
EOF
assert_exit 0 lmf component --targets-file "$targets" validate
invalid component "comp-size: unknown target 'comp'"
buffer=$settings_work/component/repo/local-maintained-files/buffer.toml
set_line "$buffer" 'schema_version = 1' $'schema_version = 1\n\n[targets.comp]\npath = "~/.config/comp/other.json"\nformat = "json"\ncreate_if_missing = false'
assert_exit 0 lmf component --targets-file "$targets" validate
assert_contains "$DS_STDOUT" "3 targets"
assert_exit 0 lmf component validate
