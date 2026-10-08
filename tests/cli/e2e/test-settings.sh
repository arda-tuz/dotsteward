# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# Settings integration. Without a settings buffer
# there is nothing to check. With one, core:settings-files asserts that
# every whole-file entry path (absent = true entries excepted) and every
# existing target path with an entry is a regular non-symlink file, buffer
# targets replacing component targets of the same name; then
# core:settings-verify runs `dotsteward settings verify` with the instance,
# HOME, <state root>/local-maintained-files and the manifest as the targets
# file: entries waiting to be written to the repository pass, entries that
# did not converge fail (one finding per engine error line), and an invalid
# buffer fails both checks.
# shellcheck source=tests/cli/e2e/helpers.sh
source "$DS_REPO_ROOT/tests/cli/e2e/helpers.sh"

settings() {
  "$agents_fw/cli/dotsteward" settings --repo "$agents_inst" --home "$HOME" \
    --state-dir "$DOTSTEWARD_STATE_ROOT/local-maintained-files" --targets-file "$agents_manifest" "$@" </dev/null
}

# No buffer: no settings check.
assert_exit 0 run_e2e --list
assert_not_contains "$DS_STDOUT" "core:settings"
assert_exit 0 run_e2e

# A component target (example-app) replaced by a buffer target of the same
# name, a component target the buffer does not replace (example-term), and
# a whole-file entry.
none='{"command": null, "versionArgv": null, "minimum": null}'
add_component example-app external "$none"
manifest_edit '.settings_targets = {
  "example-app": {component: "example-app", path: "~/.config/wrong/settings.json", format: "json",
    backup: true, create_if_missing: false, create_mode: "0644", reload: null},
  "example-term": {component: "example-app", path: "~/.config/example-term/config.toml", format: "toml",
    backup: true, create_if_missing: true, create_mode: "0644", reload: null}}'
write_buffer <<'TOML'
schema_version = 1

[targets.example-app]
path = "~/.config/example-app/settings.json"
format = "json"
create_if_missing = false

[[entries]]
id = "app-theme"
target = "example-app"
key = ["theme"]
value = "dark"

[[entries]]
id = "term-font"
target = "example-term"
key = ["font", "size"]
value = 12

[[entries]]
id = "alpha-script"
kind = "file"
path = "~/.local/bin/alpha-status"
source = "alpha-status.sh"
mode = "0755"
TOML
printf '#!/bin/sh\necho alpha\n' >"$agents_inst/local-maintained-files/files/alpha-status.sh"
chmod 0755 "$agents_inst/local-maintained-files/files/alpha-status.sh"
publish_instance

mkdir -p "$HOME/.config/example-app"
printf '{\n  "theme": "light"\n}\n' >"$HOME/.config/example-app/settings.json"
mkdir -p "$HOME/.config/wrong"
ln -s "$HOME/.config/example-app/settings.json" "$HOME/.config/wrong/settings.json"

# First contact: the live value differs and no base exists; the file entry
# is missing; the toml target does not exist yet, which is not a
# settings-files finding, but its entry has not converged until apply
# creates it (create_if_missing).
assert_exit 1 run_e2e --json --keep-going
assert_eq "$(jq -cn --arg home "$HOME" '[
  ["core:settings-files", "settings-file-missing", ($home + "/.local/bin/alpha-status")],
  ["core:settings-verify", "settings-not-converged", "app-theme"],
  ["core:settings-verify", "settings-not-converged", "term-font"],
  ["core:settings-verify", "settings-not-converged", "alpha-script"]]')" "$(findings)"
assert_contains "$DS_STDOUT" "settings file entry alpha-script missing: $HOME/.local/bin/alpha-status"
assert_contains "$DS_STDOUT" "app-theme: first-contact"
assert_contains "$DS_STDERR" "[local-maintained-files] ERROR: app-theme: first-contact"

assert_exit 0 settings apply
assert_exit 0 run_e2e
[[ -f $HOME/.config/example-term/config.toml ]] || ds_fail "apply created the toml target"

# A local change waiting for a flush passes.
printf '{\n  "theme": "solarized"\n}\n' >"$HOME/.config/example-app/settings.json"
assert_exit 0 run_e2e
assert_contains "$DS_STDOUT" "app-theme: local-changed"
printf '{\n  "theme": "dark"\n}\n' >"$HOME/.config/example-app/settings.json"

# A missing target without create_if_missing is deferred until the
# application writes it: no finding.
mv "$HOME/.config/example-app/settings.json" "$DS_TEST_ROOT/settings.json"
assert_exit 0 run_e2e
assert_contains "$DS_STDOUT" "app-theme: the target file does not exist yet; deferred"
mv "$DS_TEST_ROOT/settings.json" "$HOME/.config/example-app/settings.json"

# A target or a file entry that is a symlink fails; the verify still runs.
mv "$HOME/.config/example-term/config.toml" "$DS_TEST_ROOT/config.toml"
ln -s "$DS_TEST_ROOT/config.toml" "$HOME/.config/example-term/config.toml"
assert_exit 1 run_e2e --json
assert_eq "$(jq -cn --arg home "$HOME" '[["core:settings-files", "settings-file-not-regular", ($home + "/.config/example-term/config.toml")]]')" \
  "$(findings)"
assert_contains "$DS_STDOUT" "settings target example-term is not a regular file: $HOME/.config/example-term/config.toml"
rm "$HOME/.config/example-term/config.toml"
mv "$DS_TEST_ROOT/config.toml" "$HOME/.config/example-term/config.toml"
mv "$HOME/.local/bin/alpha-status" "$DS_TEST_ROOT/alpha-status"
ln -s "$DS_TEST_ROOT/alpha-status" "$HOME/.local/bin/alpha-status"
assert_exit 1 run_e2e
assert_contains "$DS_STDERR" "settings file entry alpha-script is not a regular file: $HOME/.local/bin/alpha-status"
rm "$HOME/.local/bin/alpha-status"
mv "$DS_TEST_ROOT/alpha-status" "$HOME/.local/bin/alpha-status"
assert_exit 0 run_e2e

# A file entry deleted locally waits for a decision in the settings engine,
# but its path is not a file: the run fails.
rm "$HOME/.local/bin/alpha-status"
assert_exit 1 run_e2e --json --keep-going
assert_eq "$(jq -cn --arg home "$HOME" '[["core:settings-files", "settings-file-missing", ($home + "/.local/bin/alpha-status")]]')" \
  "$(findings)"
assert_contains "$DS_STDERR" "alpha-script: local-deleted"
assert_exit 0 settings resolve alpha-script --remote
assert_exit 0 run_e2e

# An entry with absent = true needs no file.
cat >>"$agents_inst/local-maintained-files/buffer.toml" <<'TOML'

[[entries]]
id = "beta-gone"
kind = "file"
path = "~/.local/bin/beta-legacy"
source = "beta-legacy.sh"
absent = true
TOML
publish_instance
assert_exit 0 run_e2e

# An invalid buffer: both settings checks fail with the engine's message.
printf '\n[[entries]]\nid = "gamma-key"\ntarget = "nowhere"\nkey = ["x"]\nvalue = 1\n' \
  >>"$agents_inst/local-maintained-files/buffer.toml"
publish_instance
assert_exit 1 run_e2e --json --keep-going
assert_eq '[["core:settings-files","settings-invalid",""],["core:settings-verify","settings-error",""]]' "$(findings)"
assert_contains "$DS_STDOUT" "gamma-key: unknown target 'nowhere'"
assert_eq "" "$(temp_dirs)"
