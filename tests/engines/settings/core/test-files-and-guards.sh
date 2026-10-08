# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and settings_* variables come from the harness and helpers.sh
# Whole-file entries, format preservation, a create-false backup-false
# target holding account data, the secret and home-path guards, symlinked
# targets, and track/untrack.
# shellcheck source=tests/engines/settings/core/helpers.sh
source "$DS_REPO_ROOT/tests/engines/settings/core/helpers.sh"

settings_machines
a_alpha=$settings_work/A/home/.config/alpha/settings.json
a_beta=$settings_work/A/home/.config/beta/config.toml
a_script=$settings_work/A/home/.config/alpha/status.sh
b_alpha=$settings_work/B/home/.config/alpha/settings.json
b_beta=$settings_work/B/home/.config/beta/config.toml
b_script=$settings_work/B/home/.config/alpha/status.sh
b_gamma=$settings_work/B/home/.gamma.json

assert_exit 0 lmf A apply
assert_exit 0 lmf A reconcile
assert_exit 0 lmf B apply
assert_exit 0 lmf B reconcile

# S9: a whole-file edit is flushed to files/ and reaches the other machine
# byte for byte with its mode.
printf '# a local edit\n' >>"$a_script"
assert_eq local-changed "$(state_of A alpha-script)"
assert_exit 0 lmf A flush
cmp -s "$a_script" "$settings_work/A/repo/local-maintained-files/files/alpha-status.sh" ||
  ds_fail "the script was not copied to files/"
publish A
pull B
assert_exit 0 lmf B apply
cmp -s "$a_script" "$b_script" || ds_fail "the script did not reach machine B"
assert_file_mode "$b_script" 0755
assert_exit 0 lmf B reconcile

# S10: only the changed line of a TOML file is written; JSON keeps its key
# order and a missing trailing newline.
cp "$a_beta" "$DS_TEST_ROOT/beta-before.toml"
set_line "$b_beta" 'onboarding = false' 'onboarding = true'
assert_eq local-changed "$(state_of B beta-onboarding)"
assert_exit 0 lmf B flush
publish B
pull A
assert_exit 0 lmf A apply
assert_eq true "$(toml_get "$a_beta" onboarding)"
changed=$(diff "$DS_TEST_ROOT/beta-before.toml" "$a_beta" | grep -c '^[<>]' || true)
assert_eq 2 "$changed" "only the changed line may be written"
assert_exit 0 lmf A reconcile
NO_NEWLINE=1 json_edit "$b_alpha" 'data = {"zzzUntracked": 1, **data}'
set_line "$a_alpha" '(\s*)"refreshInterval": 30' '    "refreshInterval": 31'
assert_exit 0 lmf A flush
publish A
pull B
assert_exit 0 lmf B apply
assert_eq 31 "$(json_get "$b_alpha" statusLine.refreshInterval)"
first_key=$(python3 -c 'import json, sys; print(next(iter(json.load(open(sys.argv[1])))))' "$b_alpha")
assert_eq zzzUntracked "$first_key" "the JSON key order was not kept"
[[ $(tail -c 1 "$b_alpha" | od -An -c | tr -d ' ') != '\n' ]] || ds_fail "a trailing newline was added"
assert_exit 0 lmf B reconcile

# S11: a create_if_missing = false, backup = false target that exists: only
# the tracked key is written, account data and mode stay, no backup.
printf '{\n  "numStartups": 3,\n  "account": {\n    "email": "user@example.invalid"\n  }\n}' >"$b_gamma"
chmod 0600 "$b_gamma"
assert_eq first-contact "$(state_of B gamma-guideline)"
assert_exit 0 lmf B apply
assert_not_contains "$DS_STDERR" "backup" "no backup is taken, so none may be named"
assert_eq "$(buffer_get B gamma-guideline)" "$(json_get "$b_gamma" guideline)"
assert_eq '"user@example.invalid"' "$(json_get "$b_gamma" account.email)"
assert_file_mode "$b_gamma" 0600
[[ -z $(find "$settings_work/B/state/backups" -name '.gamma.json') ]] || ds_fail "the gamma file was backed up"

# S12: secret-like keys and absolute home paths never enter the buffer.
assert_exit 2 lmf A track --id secret1 --target alpha --key env.SERVICE_API_KEY
buffer_has "$settings_work/A/repo" secret1 && ds_fail "a secret-like key was tracked"
set_line "$a_beta" 'mode = "enabled"' "mode = \"$settings_work/A/home/private\""
assert_exit 2 lmf A flush
assert_eq '"enabled"' "$(buffer_get A beta-mode)"
set_line "$a_beta" 'mode = ".*/private"' 'mode = "enabled"'

# S13: the engine never writes through a symlink.
mkdir -p "$DS_TEST_ROOT/ro"
cp "$b_beta" "$DS_TEST_ROOT/ro/config.toml"
chmod 0444 "$DS_TEST_ROOT/ro/config.toml"
rm -f "$b_beta"
ln -s "$DS_TEST_ROOT/ro/config.toml" "$b_beta"
set_line "$a_beta" 'onboarding = true' 'onboarding = false'
assert_exit 0 lmf A flush
publish A
pull B
assert_exit 2 lmf B apply
assert_symlink_to "$b_beta" "$DS_TEST_ROOT/ro/config.toml"
assert_eq true "$(toml_get "$DS_TEST_ROOT/ro/config.toml" onboarding)"

# S14: tracking a missing key records it as absent; untrack removes it.
assert_exit 0 lmf A track --id track1 --target beta --key model
assert_eq '<absent>' "$(buffer_get A track1)"
assert_exit 0 lmf A untrack track1
buffer_has "$settings_work/A/repo" track1 && ds_fail "untrack left the entry"
assert_exit 0 lmf A track --id track2 --target beta --key-json '["notifications", "sound"]' --note "a note"
assert_eq '<absent>' "$(buffer_get A track2)"
assert_exit 0 lmf A untrack track2
assert_exit 2 lmf A untrack missing-id
true
