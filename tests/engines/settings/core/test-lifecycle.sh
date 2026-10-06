# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and settings_* variables come from the harness and helpers.sh
# The three-way buffer lifecycle on two machines sharing one bare remote
# (the S1-S8b scenarios of the original engine): fresh apply, idempotency,
# local changes and flush, first contact on a second machine, remote
# changes, conflicts with both resolutions, deletions, typed equality and
# whole tables.
# shellcheck source=tests/engines/settings/core/helpers.sh
source "$DS_REPO_ROOT/tests/engines/settings/core/helpers.sh"

settings_machines
a_alpha=$settings_work/A/home/.config/alpha/settings.json
a_beta=$settings_work/A/home/.config/beta/config.toml
a_script=$settings_work/A/home/.config/alpha/status.sh
b_alpha=$settings_work/B/home/.config/alpha/settings.json
b_beta=$settings_work/B/home/.config/beta/config.toml

# S1: a fresh machine gets the repository values on first contact; the
# target that is never created stays missing and its entry is deferred.
assert_exit 0 lmf A apply
for file in "$a_alpha" "$a_beta" "$a_script"; do
  [[ -f $file && ! -L $file ]] || ds_fail "not created as a regular file: $file"
done
[[ ! -e $settings_work/A/home/.gamma.json ]] || ds_fail "a create_if_missing = false target was created"
assert_file_mode "$a_script" 0755
assert_file_mode "$a_beta" 0600
assert_file_mode "$a_alpha" 0644
cmp -s "$a_script" "$settings_fixtures/buffer/files/alpha-status.sh" || ds_fail "the whole-file entry differs from files/"
# The rendering of created files equals the original engine's output.
cmp -s "$a_alpha" "$settings_fixtures/golden/alpha-settings.json" || ds_fail "alpha settings differ from the golden file"
cmp -s "$a_beta" "$settings_fixtures/golden/beta-config.toml" || ds_fail "beta config differs from the golden file"
assert_eq "$(buffer_get A beta-threads)" "$(toml_get "$a_beta" agents.max_threads)"
assert_eq "$(buffer_get A alpha-status)" "$(json_get "$a_alpha" statusLine)"
assert_eq "$(buffer_get A beta-ui)" "$(toml_get "$a_beta" ui)"
assert_eq '"enabled"' "$(toml_get "$a_beta" notifications.preferences.mode)"
assert_eq '<absent>' "$(toml_get "$a_beta" theme)"
assert_eq deferred "$(state_of A gamma-guideline)"
assert_eq in-sync "$(state_of A beta-threads)"
assert_exit 0 lmf A verify

# S2: a second apply with nothing to do writes nothing.
before=$(sha256sum "$a_alpha" "$a_beta" "$a_script")
journal_before=$(wc -l <"$settings_work/A/state/journal.jsonl")
assert_exit 0 lmf A apply
assert_eq "$before" "$(sha256sum "$a_alpha" "$a_beta" "$a_script")" "second apply changed files"
assert_eq "$journal_before" "$(wc -l <"$settings_work/A/state/journal.jsonl")" "second apply journaled writes"
assert_exit 0 lmf A reconcile

# S3: a local change survives apply and flush writes it to the buffer; the
# user's own comment and tables in the file stay.
set_line "$a_beta" 'max_threads = .*' 'max_threads = 20'
printf '\n# my own comment\n[projects."/srv/example"]\ntrust_level = "trusted"\n' >>"$a_beta"
assert_eq local-changed "$(state_of A beta-threads)"
assert_exit 0 lmf A apply
assert_eq 20 "$(toml_get "$a_beta" agents.max_threads)" "apply reverted a local change"
assert_exit 0 lmf A flush
assert_eq 20 "$(buffer_get A beta-threads)"
grep -Fq '# my own comment' "$a_beta" || ds_fail "the user's comment was lost"
publish A
assert_eq in-sync "$(state_of A beta-threads)"

# S4: a second machine with its own file: the repository wins on first
# contact, untracked keys stay, the file is backed up and the write is
# journaled.
pull B
mkdir -p "$(dirname "$b_beta")"
printf 'model = "own-model"\n\n[agents]\nmax_threads = 7\n' >"$b_beta"
assert_exit 0 lmf B apply
assert_eq 20 "$(toml_get "$b_beta" agents.max_threads)"
assert_eq '"own-model"' "$(toml_get "$b_beta" model)"
[[ -n $(find "$settings_work/B/state/backups" -type f -name config.toml) ]] || ds_fail "no backup on first contact"
grep -Fq '"beta-threads"' "$settings_work/B/state/journal.jsonl" || ds_fail "the journal lacks beta-threads"
assert_exit 0 lmf B reconcile

# S5: a remote change reaches the other machine through pull and apply.
set_line "$a_beta" 'max_threads = .*' 'max_threads = 30'
assert_exit 0 lmf A flush
publish A
pull B
assert_eq remote-changed "$(state_of B beta-threads)"
assert_exit 0 lmf B apply
assert_eq 30 "$(toml_get "$b_beta" agents.max_threads)"
assert_exit 0 lmf B reconcile
assert_eq in-sync "$(state_of B beta-threads)"

# S6: a conflict blocks the non-interactive paths; both resolutions work.
set_line "$a_beta" 'max_threads = .*' 'max_threads = 40'
assert_exit 0 lmf A flush
publish A
set_line "$b_beta" 'max_threads = .*' 'max_threads = 45'
pull B
assert_eq conflict "$(state_of B beta-threads)"
assert_eq true "$(status_field B beta-threads .needs_decision)"
assert_exit 0 lmf B apply
assert_eq 45 "$(toml_get "$b_beta" agents.max_threads)" "apply wrote a conflict"
assert_contains "$DS_STDERR" "dotsteward-maintain"
assert_exit 1 lmf B verify
assert_exit 0 lmf B resolve beta-threads --remote
assert_eq 40 "$(toml_get "$b_beta" agents.max_threads)"
assert_exit 0 lmf B verify
assert_exit 0 lmf B reconcile
set_line "$a_beta" 'max_threads = .*' 'max_threads = 41'
assert_exit 0 lmf A flush
publish A
set_line "$b_beta" 'max_threads = .*' 'max_threads = 46'
pull B
assert_eq conflict "$(state_of B beta-threads)"
assert_exit 0 lmf B resolve beta-threads --local
assert_eq 46 "$(buffer_get B beta-threads)"
publish B
pull A
assert_eq remote-changed "$(state_of A beta-threads)"
assert_exit 0 lmf A apply
assert_eq 46 "$(toml_get "$a_beta" agents.max_threads)"
assert_exit 0 lmf A reconcile

# S7: a local deletion is never flushed without a decision; once decided it
# reaches the other machine and the sibling key stays.
json_edit "$a_alpha" 'del data["env"]["DEFAULT_MODEL"]'
assert_eq local-deleted "$(state_of A alpha-env-model)"
assert_exit 3 lmf A flush
assert_eq '"small"' "$(buffer_get A alpha-env-model)" "flush wrote an undecided deletion"
assert_exit 0 lmf A resolve alpha-env-model --local
assert_eq '<absent>' "$(buffer_get A alpha-env-model)"
publish A
pull B
assert_exit 0 lmf B apply
assert_eq '<absent>' "$(json_get "$b_alpha" env.DEFAULT_MODEL)"
assert_eq "$(buffer_get B alpha-env-limit)" "$(json_get "$b_alpha" env.SEARCH_LIMIT)"
assert_exit 0 lmf B reconcile

# S8: typed equality: true and 1 differ.
set_line "$a_beta" 'copy_on_select = true' 'copy_on_select = 1'
assert_eq local-changed "$(state_of A beta-ui)"
set_line "$a_beta" 'copy_on_select = 1' 'copy_on_select = true'
assert_eq in-sync "$(state_of A beta-ui)"

# S8b: a key added inside a tracked whole table travels with the table, and
# the other machine gets exactly one added line.
python3 - "$a_beta" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace("[ui]\n", '[ui]\nstatus_indicators = "beta"\n', 1)
open(path, "w", encoding="utf-8").write(text)
PY
assert_eq '"beta"' "$(toml_get "$a_beta" ui.status_indicators)"
assert_eq local-changed "$(state_of A beta-ui)"
assert_exit 0 lmf A flush
assert_eq "$(toml_get "$a_beta" ui)" "$(buffer_get A beta-ui)"
publish A
pull B
cp "$b_beta" "$DS_TEST_ROOT/beta-before.toml"
assert_exit 0 lmf B apply
assert_eq '"beta"' "$(toml_get "$b_beta" ui.status_indicators)"
changed=$(diff "$DS_TEST_ROOT/beta-before.toml" "$b_beta" | grep -c '^[<>]' || true)
assert_eq 1 "$changed" "only the new line may be written"
assert_exit 0 lmf B reconcile
assert_exit 0 lmf B verify
