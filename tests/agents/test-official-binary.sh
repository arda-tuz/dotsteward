# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Phase 1 of the agents installer (SPEC 8.1, 3.4): every active component
# whose method is official-binary is installed at the user level in both
# profile modes (the methods engine: verified download, backup of the old
# binary in <state>/backups/<UTC>/files/<abs>, at-least keeps a newer
# binary); check fails with the rebuild hint when it is missing or older.
# The phase runs before the skill layout, and components of other methods
# or not active in the profile are left alone.
# shellcheck source=tests/agents/helpers.sh
source "$DS_REPO_ROOT/tests/agents/helpers.sh"

ds_use_stubs curl
url=https://downloads.example.invalid/releases/example-term-1.1.0.tar.gz
dest=$HOME/.local/bin/example-term

# make_release REPORTED OUT: an archive whose example-term prints
# "example-term REPORTED".
make_release() {
  local dir
  dir=$(mktemp -d "$DS_TEST_ROOT/release.XXXXXX")
  printf '#!%s\nprintf "example-term %%s\\n" %q\n' "$BASH" "$1" >"$dir/example-term"
  chmod 0755 "$dir/example-term"
  tar -czf "$2" -C "$dir" example-term
  rm -rf -- "$dir"
}
make_release 1.1.0 "$DS_TEST_ROOT/release.tar.gz"
pin_download agent_tools.example-term "$DS_TEST_ROOT/release.tar.gz" "$url" 1.1.0
add_component example-term official-binary '{
  "pin": "agent_tools.example-term",
  "asset": {"linux": "example-term-{version}.tar.gz", "darwin": "example-term-{version}.tar.gz"},
  "member": "example-term",
  "dest": "~/.local/bin/example-term",
  "versionArgv": ["--version"],
  "versionRegex": "example-term ([0-9][0-9.]*)",
  "policy": "at-least",
  "verify": "sha256"
}'
# Not active in the check profile: never installed by it.
add_component example-app official-binary '{
  "pin": "agent_tools.example-app",
  "asset": {"linux": "x", "darwin": "x"},
  "member": "example-app",
  "dest": "~/.local/bin/example-app",
  "versionArgv": ["--version"],
  "versionRegex": "([0-9.]+)",
  "policy": "exact",
  "verify": "sha256"
}' '["fresh"]'
add_component alpha external '{"command": null, "versionArgv": null, "minimum": null}'

before=$(home_state)
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "example-term (official-binary): example-term 1.1.0 or newer not found (found none); run 'dotsteward rebuild --profile workstation --switch'"
assert_not_contains "$DS_STDERR" "canonical skill directory missing"
assert_eq "$before" "$(home_state)"

assert_exit 0 run_agents install
assert_contains "$DS_STDOUT" "example-term (official-binary): downloading $url"
assert_file_mode "$dest" 0755
assert_eq "$("$dest" --version)" "example-term 1.1.0"
assert_call_count 1 curl
assert_exit 0 run_agents check
assert_call_count 1 curl

# An older binary is backed up and replaced; a newer one is kept.
printf '#!%s\necho "example-term 1.0.0"\n' "$BASH" >"$dest"
assert_exit 0 run_agents install
assert_eq "$("$dest" --version)" "example-term 1.1.0"
backup=$(find "$DOTSTEWARD_STATE_ROOT/backups" -path "*/files$dest" | head -n 1)
assert_eq "$(cat "$backup")" "$(printf '#!%s\necho "example-term 1.0.0"' "$BASH")"
printf '#!%s\necho "example-term 2.0.0"\n' "$BASH" >"$dest"
assert_exit 0 run_agents install
assert_eq "$("$dest" --version)" "example-term 2.0.0"
assert_call_count 2 curl

# Install failures stop before the layout.
rm -rf "$HOME/.agents" "$dest"
ln -s "$DS_TEST_ROOT/elsewhere" "$dest"
assert_exit 1 run_agents install
assert_contains "$DS_STDERR" "refusing to replace a symlink or non-regular file: $dest"
[[ ! -e $HOME/.agents ]] || ds_fail "phase 1 runs before the layout"
assert_eq "$(temp_dirs)" "" "no temporary directory is left behind"
