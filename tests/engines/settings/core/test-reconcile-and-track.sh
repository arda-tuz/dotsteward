# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and settings_* variables come from the harness and helpers.sh
# Reconcile edges (no published ref, an invalid published buffer, pruning
# after untrack, a published file entry without its blob), track-file,
# deferred entries whose target appears later, and first contact with an
# entry the repository marks absent.
# shellcheck source=tests/engines/settings/core/helpers.sh
source "$DS_REPO_ROOT/tests/engines/settings/core/helpers.sh"

# No published ref: reconcile changes nothing, not even stale records.
settings_repo "$settings_work/L/repo"
mkdir -p "$settings_work/L/home" "$settings_work/L/state"
printf '{\n  "entries": {\n    "alpha|[\\"gone\\"]": {\n      "value": 1\n    }\n  },\n  "schema_version": 1\n}\n' \
  >"$settings_work/L/state/base.json"
before=$(sha "$settings_work/L/state/base.json")
assert_exit 0 lmf L reconcile
assert_contains "$DS_STDOUT" "origin/main"
assert_exit 0 lmf L apply
assert_eq "$before" "$(sha "$settings_work/L/state/base.json")"
assert_json - '.published_available == false and ([.entries[].base] | unique == [null])' \
  <<<"$(lmf L status --json)"

# A literal "~" for the buffer's home paths.
tilde='~'

settings_machines
a_home=$settings_work/A/home
a_state=$settings_work/A/state
assert_exit 0 lmf A apply
assert_json "$a_state/base.json" '.entries | has("beta|[\"plugins\"]")'

# untrack, publish, reconcile: the record of the removed entry is pruned.
assert_exit 0 lmf A untrack beta-plugins
assert_eq '["one","two"]' "$(toml_get "$a_home/.config/beta/config.toml" plugins | tr -d ' ')" "untrack touched the live file"
publish A
assert_json "$a_state/base.json" '.entries | has("beta|[\"plugins\"]") | not'

# A published file entry whose blob is missing is skipped by reconcile.
printf 'notes\n' >"$a_home/notes.txt"
chmod 0640 "$a_home/notes.txt"
assert_exit 0 lmf A track-file --id notes --path "$tilde/notes.txt" --source notes.txt
assert_eq 640 "$(stat -c %a "$settings_work/A/repo/local-maintained-files/files/notes.txt")"
assert_eq '"0640"' "$(status_field A notes '.repo.mode')"
git -C "$settings_work/A/repo" add local-maintained-files/buffer.toml
git -C "$settings_work/A/repo" commit -q -m "chore: track notes without the file"
git -C "$settings_work/A/repo" push -q origin main
assert_exit 0 lmf A reconcile
assert_eq in-sync "$(state_of A notes)"
assert_eq null "$(status_field A notes .base)"
git -C "$settings_work/A/repo" add -A
git -C "$settings_work/A/repo" commit -q -m "chore: add the notes file"
git -C "$settings_work/A/repo" push -q origin main
assert_exit 0 lmf A reconcile
assert_eq '{"mode":"0640","sha256":"'"$(sha "$a_home/notes.txt")"'"}' "$(status_field A notes '.base')"

# An invalid published buffer: a warning, and the base does not move.
pull B
sed -i 's/^schema_version = 1$/schema_version = 9/' "$settings_work/B/repo/local-maintained-files/buffer.toml"
git -C "$settings_work/B/repo" commit -q -am "chore: break the buffer"
git -C "$settings_work/B/repo" push -q origin main
git -C "$settings_work/A/repo" fetch -q origin
before=$(sha "$a_state/base.json")
assert_exit 0 lmf A reconcile
assert_contains "$DS_STDERR" "WARNING"
assert_contains "$DS_STDERR" "published buffer"
assert_eq "$before" "$(sha "$a_state/base.json")"
assert_json - '.published_available == false' <<<"$(lmf A status --json)"

# track-file: --mode wins over the live mode; content with the absolute home
# path, a path outside the home, a symlink, a missing file and a duplicate
# id are refused without writing anything.
printf '#!/bin/sh\necho hi\n' >"$a_home/tool.sh"
chmod 0755 "$a_home/tool.sh"
assert_exit 0 lmf A track-file --id tool --path "$tilde/tool.sh" --source tool.sh --mode 0700
assert_eq 700 "$(stat -c %a "$settings_work/A/repo/local-maintained-files/files/tool.sh")"
assert_eq '"0700"' "$(status_field A tool '.repo.mode')"
assert_eq first-contact "$(state_of A tool)" "a live mode different from --mode"
assert_exit 2 lmf A track-file --id tool --path "$tilde/tool.sh" --source tool2.sh
printf 'cd %s/projects\n' "$a_home" >"$a_home/private.sh"
assert_exit 2 lmf A track-file --id private --path "$tilde/private.sh" --source private.sh
printf 'outside\n' >"$DS_TEST_ROOT/outside.txt"
assert_exit 2 lmf A track-file --id outside --path "$DS_TEST_ROOT/outside.txt" --source outside.txt
ln -s "$a_home/tool.sh" "$a_home/link.sh"
assert_exit 2 lmf A track-file --id link --path "$tilde/link.sh" --source link.sh
assert_exit 2 lmf A track-file --id missing --path "$tilde/missing.sh" --source missing.sh
for source in tool2.sh private.sh outside.txt link.sh missing.sh; do
  [[ ! -e $settings_work/A/repo/local-maintained-files/files/$source ]] || ds_fail "files/$source was written"
done
for id in private outside link missing; do
  buffer_has "$settings_work/A/repo" "$id" && ds_fail "entry $id was added"
done
# untrack of a file entry removes its files/ copy, never the live file.
assert_exit 0 lmf A untrack tool
[[ ! -e $settings_work/A/repo/local-maintained-files/files/tool.sh ]] || ds_fail "untrack kept files/tool.sh"
[[ -f $a_home/tool.sh ]] || ds_fail "untrack removed the live file"

# A deferred entry becomes a first contact when its target appears, and
# apply then writes it.
settings_repo "$settings_work/C/repo"
mkdir -p "$settings_work/C/home"
c_home=$settings_work/C/home
assert_exit 0 lmf C apply
assert_eq deferred "$(state_of C gamma-guideline)"
printf '{}\n' >"$c_home/.gamma.json"
assert_eq first-contact "$(state_of C gamma-guideline)"
assert_exit 0 lmf C apply
assert_eq '"short"' "$(json_get "$c_home/.gamma.json" guideline)"
assert_eq in-sync "$(state_of C gamma-guideline)"

# First contact with an entry the repository marks absent deletes the live
# key, after a backup that the warning names.
settings_repo "$settings_work/D/repo"
mkdir -p "$settings_work/D/home/.config/beta"
printf 'theme = "neon"\nother = 1\n' >"$settings_work/D/home/.config/beta/config.toml"
assert_eq first-contact "$(state_of D beta-theme)"
assert_exit 0 lmf D apply
assert_eq '<absent>' "$(toml_get "$settings_work/D/home/.config/beta/config.toml" theme)"
assert_eq 1 "$(toml_get "$settings_work/D/home/.config/beta/config.toml" other)"
backup=$(find "$settings_work/D/state/backups" -type f -name config.toml)
[[ -n $backup ]] || ds_fail "no backup before deleting a key"
assert_eq '"neon"' "$(toml_get "$backup" theme)"
assert_contains "$DS_STDERR" "beta-theme"
assert_contains "$DS_STDERR" "$backup"
