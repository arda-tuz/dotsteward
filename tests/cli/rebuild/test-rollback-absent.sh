# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# rollback --latest, ABSENT branch (SPEC 6.2, A-14): when no Home Manager
# existed before the first install, rollback sets the platform default login
# shell, removes the shells-file line this system added, removes the managed
# links of the current generation's manifest (only links into the Nix
# store), restores the force-linked files from the newest backup with their
# mode, and leaves settings files, Nix and the packages alone. Every managed
# link is checked before anything changes. --dry-run prints the plan (text,
# or JSON with step ids and paths only) and changes nothing.
# shellcheck source=tests/cli/rebuild/helpers.sh
source "$DS_REPO_ROOT/tests/cli/rebuild/helpers.sh"

shells=$DOTSTEWARD_ETC_SHELLS
rules=$HOME/.example-app/AGENTS.md
manifest_edit '.managed_links = ["~/.zshrc", "~/.config/example-term/term.conf", "~/.example-app/AGENTS.md"]
  | .force_linked_restore = [{ component: "example-app", path: "~/.example-app/AGENTS.md", mode: "0664" }]'

# The machine as rebuild --switch left it.
mkdir -p "$rb_current"
printf 'ABSENT\n' >"$rb_current/previous-generation"
printf '%s\n' "$rb_zsh" >>"$shells"
printf '%s\n' "$rb_zsh" >"$rb_current/etc-shells-added-path"
ds_passwd_set "$USER" "$rb_zsh"
store_link "$HOME/.zshrc"
store_link "$HOME/.config/example-term/term.conf"
store_link "$rules"
mkdir -p "$HOME/.config/example-app"
printf '{ "tracked": true }\n' >"$HOME/.config/example-app/settings.json"
mkdir -p "$rb_state/backups/20250101T000000Z-bootstrap/files$HOME/.example-app" \
  "$rb_state/backups/20260101T000000Z-bootstrap/files$HOME/.example-app"
printf 'older rules\n' >"$rb_state/backups/20250101T000000Z-bootstrap/files$rules"
printf 'original rules\n' >"$rb_state/backups/20260101T000000Z-bootstrap/files$rules"
newest_backup=$rb_state/backups/20260101T000000Z-bootstrap/files$rules

snapshot() {
  printf '%s\n%s\n%s\n' "$(tree_state "$HOME")" "$(tree_state "$rb_state")" "$(sha256sum "$shells")"
}
before=$(snapshot)

# The text plan.
assert_exit 0 run_rollback --latest --dry-run
assert_eq "1. Set the login shell of $USER to /bin/bash
2. Remove the login shell line this system added to $shells: $rb_zsh
3. Remove the 3 managed Nix links (there was no Home Manager before the first install)
4. Restore the backed-up force-linked files with their modes: $rules
5. Settings files synced by local-maintained-files stay in place as user data
6. Nix, the packages and user data stay installed
Backup of $rules: $newest_backup" "$DS_STDOUT"

# The JSON plan: paths only, one object per step.
assert_exit 0 run_rollback --latest --dry-run --json
printf '%s\n' "$DS_STDOUT" >"$DS_TEST_ROOT/plan.json"
assert_json "$DS_TEST_ROOT/plan.json" "
  .schema_version == 1
  and .manifest == \"$rb_manifest\"
  and .previous_generation == \"ABSENT\"
  and ([.steps[].id] == [\"login-shell\", \"shells-line\", \"home-manager\", \"restore\", \"keep-settings\", \"keep-packages\"])
  and .steps[0] == { id: \"login-shell\", action: \"set\", user: \"$USER\", shell: \"/bin/bash\" }
  and .steps[1] == { id: \"shells-line\", action: \"remove\", file: \"$shells\", path: \"$rb_zsh\" }
  and .steps[2] == { id: \"home-manager\", action: \"remove-links\", generation: null,
    links: [\"$HOME/.zshrc\", \"$HOME/.config/example-term/term.conf\", \"$rules\"] }
  and .steps[3] == { id: \"restore\", files: [{ path: \"$rules\", mode: \"0664\", backup: \"$newest_backup\" }] }"
assert_eq "$before" "$(snapshot)" "the dry run changed something"
assert_calls

# Refusals before any change: a user file or a link outside the store at a
# managed link.
mv "$HOME/.config/example-term/term.conf" "$DS_TEST_ROOT/term-link"
printf 'mine\n' >"$HOME/.config/example-term/term.conf"
assert_exit 1 run_rollback --latest --apply
assert_contains "$DS_STDERR" "[dotsteward] ERROR: rollback will not overwrite a user file: $HOME/.config/example-term/term.conf"
rm -f -- "$HOME/.config/example-term/term.conf"
ln -s "$HOME/.config/example-app/settings.json" "$HOME/.config/example-term/term.conf"
assert_exit 1 run_rollback --latest --apply
assert_contains "$DS_STDERR" "[dotsteward] ERROR: managed link points outside the Nix store: $HOME/.config/example-term/term.conf -> $HOME/.config/example-app/settings.json"
rm -f -- "$HOME/.config/example-term/term.conf"
mv "$DS_TEST_ROOT/term-link" "$HOME/.config/example-term/term.conf"
assert_eq "$before" "$(snapshot)" "a refused rollback changed something"
assert_calls

# The rollback.
assert_exit 0 run_rollback --latest --apply
assert_eq "/bin/bash" "$(ds_passwd_field "$USER" 7)"
assert_eq "sudo chsh -s /bin/bash $USER" "$(ds_calls_of sudo | grep chsh)"
assert_eq 1 "$(ds_call_count sudo 'install -o root -g root -m 0644 *')"
assert_not_contains "$(<"$shells")" "$rb_zsh"
assert_contains "$(<"$shells")" "/bin/bash"
for link in "$HOME/.zshrc" "$HOME/.config/example-term/term.conf"; do
  [[ ! -e $link && ! -L $link ]] || ds_fail "managed link not removed: $link"
done
[[ -f $rules && ! -L $rules ]] || ds_fail "the force-linked file was not restored as a regular file"
assert_eq "original rules" "$(<"$rules")"
assert_file_mode "$rules" 664
assert_eq '{ "tracked": true }' "$(<"$HOME/.config/example-app/settings.json")"
assert_contains "$DS_STDOUT" "[dotsteward] setting the login shell to /bin/bash"
assert_contains "$DS_STDOUT" "[dotsteward] rollback finished; Nix and the packages stay installed"
assert_eq 0 "$(ds_call_count activate)"

# A second rollback finds no links and no shells line left; without a
# backup the restore is skipped with a warning.
rm -rf -- "$rb_state/backups"
rm -f -- "$rules"
: >"$DS_CALL_LOG"
assert_exit 0 run_rollback --latest --dry-run
assert_contains "$DS_STDOUT" "Backup of $rules: none; the restore is skipped"
assert_contains "$DS_STDOUT" "2. No login shell line added by this system to remove"
assert_exit 0 run_rollback --latest --apply
assert_contains "$DS_STDERR" "[dotsteward] WARNING: no backup of $rules; it did not exist before the first install, the restore is skipped"
[[ ! -e $rules ]] || ds_fail "a file was restored without a backup"
assert_eq 0 "$(ds_call_count sudo)" "the login shell is already the default and no line is left"

# An instance that does not manage the login shell keeps it.
manifest_edit '.login_shell = null'
ds_passwd_set "$USER" "$rb_zsh"
: >"$DS_CALL_LOG"
assert_exit 0 run_rollback --latest --dry-run
assert_contains "$DS_STDOUT" "1. Leave the login shell of $USER unchanged (the instance does not manage it)"
assert_exit 0 run_rollback --latest --dry-run --json
printf '%s\n' "$DS_STDOUT" >"$DS_TEST_ROOT/plan.json"
assert_json "$DS_TEST_ROOT/plan.json" ".steps[0] == { id: \"login-shell\", action: \"keep\", user: \"$USER\", shell: null }"
assert_exit 0 run_rollback --latest --apply
assert_eq "$rb_zsh" "$(ds_passwd_field "$USER" 7)"
assert_eq 0 "$(ds_call_count sudo)"
