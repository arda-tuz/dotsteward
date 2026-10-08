# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Adoption before activation (rebuild.adoptPaths): a regular
# file at an adopt path is backed up into <state>/backups/<UTC>-adopt and
# removed so Home Manager can link it; an absent path and a link into the
# Nix store are left alone; a link outside the store and a directory are
# refused. Every path is checked before the first one is
# changed, and adoption runs after the previous-generation capture and
# before activate.
# shellcheck source=tests/cli/rebuild/helpers.sh
source "$DS_REPO_ROOT/tests/cli/rebuild/helpers.sh"

manifest_edit '.adopt_paths = ["~/.config/example-app/config.json", "~/.config/example-term/term.conf", "~/.absent"]'
mkdir -p "$HOME/.config/example-app"
printf '{ "old": true }\n' >"$HOME/.config/example-app/config.json"
chmod 0644 "$HOME/.config/example-app/config.json"
store_link "$HOME/.config/example-term/term.conf"
term_target=$(readlink "$HOME/.config/example-term/term.conf")

# A link outside the store at the second path: nothing is adopted.
rm -f -- "$HOME/.config/example-term/term.conf"
ln -s "$HOME/.config/elsewhere" "$HOME/.config/example-term/term.conf"
printf 'x\n' >"$HOME/.config/elsewhere"
assert_exit 1 run_rebuild --profile workstation --switch
assert_contains "$DS_STDERR" "[dotsteward] ERROR: adopt path points outside the Nix store: $HOME/.config/example-term/term.conf -> $HOME/.config/elsewhere"
[[ -f $HOME/.config/example-app/config.json ]] || ds_fail "the first path was adopted before the refusal"
[[ ! -e $rb_state/backups ]] || ds_fail "a backup was made before the refusal"
assert_eq 0 "$(ds_call_count activate)"

# A directory is refused.
rm -f -- "$HOME/.config/example-term/term.conf"
mkdir -p "$HOME/.config/example-term/term.conf"
assert_exit 1 run_rebuild --profile workstation --switch
assert_contains "$DS_STDERR" "[dotsteward] ERROR: adopt path is not a regular file: $HOME/.config/example-term/term.conf"
rmdir "$HOME/.config/example-term/term.conf"

# The happy path: the file is backed up privately and removed before
# activate; the store link stays.
ln -s "$term_target" "$HOME/.config/example-term/term.conf"
ds_stub_override activate <<EOF
#!$BASH
if [[ -e $(printf %q "$HOME/.config/example-app/config.json") ]]; then
  echo "activate saw the unadopted file" >&2
  exit 9
fi
EOF
: >"$DS_CALL_LOG"
assert_exit 0 run_rebuild --profile workstation --switch
assert_contains "$DS_STDOUT" "[dotsteward] previous file backed up and handed over to Home Manager: $HOME/.config/example-app/config.json"
mapfile -t backups < <(find "$rb_state/backups" -mindepth 1 -maxdepth 1 -name '*-adopt')
assert_eq 1 "${#backups[@]}"
[[ ${backups[0]##*/} =~ ^[0-9]{8}T[0-9]{6}Z-adopt$ ]] || ds_fail "unexpected backup name: ${backups[0]}"
copy=${backups[0]}/files$HOME/.config/example-app/config.json
assert_eq '{ "old": true }' "$(<"$copy")"
assert_file_mode "$copy" 600
assert_file_mode "${backups[0]}" 700
assert_symlink_to "$HOME/.config/example-term/term.conf" "$term_target"
assert_eq 1 "$(ds_call_count activate)"

# A second run has nothing left to adopt.
: >"$DS_CALL_LOG"
assert_exit 0 run_rebuild --profile workstation --switch
assert_not_contains "$DS_STDOUT" "handed over"
