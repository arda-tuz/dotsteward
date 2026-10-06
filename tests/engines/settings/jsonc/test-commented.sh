# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and settings_* variables come from the harness and helpers.sh
# A JSONC target whose live file has comments or trailing commas (the files
# an editor-style application writes): every row of that target is an error
# row naming the file, so apply, flush, resolve and track refuse with exit 2
# before any write, verify exits 1, and the rows of other targets and the
# whole-file entries (never parsed, so comments are fine there) are
# evaluated as usual. An unterminated block comment is a parse error. Once
# the comments are gone, the target works like JSON.
# shellcheck source=tests/engines/settings/core/helpers.sh
source "$DS_REPO_ROOT/tests/engines/settings/core/helpers.sh"

jsonc_fixtures=$DS_REPO_ROOT/tests/engines/settings/jsonc/fixtures
settings_repo "$settings_work/M/repo" "$jsonc_fixtures/buffer"
home=$settings_work/M/home
delta=$home/.config/delta/settings.json
epsilon=$home/.config/epsilon/settings.json
keys=$home/.config/delta/keybindings.json
buffer=$settings_work/M/repo/local-maintained-files/buffer.toml
state=$settings_work/M/state
mkdir -p "$(dirname "$delta")"
cp "$jsonc_fixtures/buffer/files/delta-keybindings.json" "$keys"
chmod 0644 "$keys"
buffer_sum=$(sha "$buffer")
message="commented JSONC file; edit it in the application or remove the comments"

for fixture in line-comments block-comments trailing-commas; do
  cp "$jsonc_fixtures/commented/$fixture.json" "$delta"
  before=$(sha "$delta")

  assert_exit 0 lmf M status
  assert_contains "$DS_STDOUT" "$message"
  for id in delta-size delta-theme delta-exclude; do
    assert_eq error "$(state_of M "$id")" "$fixture: $id"
    assert_eq "\"$message: $delta\"" "$(status_field M "$id" .error)" "$fixture: $id"
    assert_eq null "$(status_field M "$id" .live)" "$fixture: $id"
  done
  assert_eq in-sync "$(state_of M delta-keys)" "$fixture: the whole-file entry"
  assert_eq first-contact "$(state_of M epsilon-mode)" "$fixture: the other target"

  assert_exit 2 lmf M apply
  assert_contains "$DS_STDERR" "delta-size: $message"
  assert_contains "$DS_STDERR" "no file is written"
  assert_exit 2 lmf M flush
  assert_exit 2 lmf M resolve delta-theme --local
  assert_exit 2 lmf M resolve delta-theme --remote
  assert_exit 2 lmf M track --id delta-tab --target delta --key-json '["editor.tabSize"]'
  assert_contains "$DS_STDERR" "$message"
  assert_exit 1 lmf M verify
  assert_contains "$DS_STDERR" "delta-exclude: $message"

  assert_eq "$before" "$(sha "$delta")" "$fixture: the commented file was written"
  assert_eq "$buffer_sum" "$(sha "$buffer")" "$fixture: the buffer was written"
  [[ ! -e $epsilon ]] || ds_fail "$fixture: apply wrote another target despite error rows"
  [[ ! -e $state/base.json && ! -e $state/backups && ! -e $state/journal.jsonl ]] ||
    ds_fail "$fixture: the machine state was written: $(find "$state" -mindepth 1)"
done

# An unterminated block comment cannot be parsed at all.
printf '{\n  "editor.fontSize": 14 /* open\n}\n' >"$delta"
assert_eq error "$(state_of M delta-size)"
assert_contains "$(status_field M delta-size .error)" "cannot parse"
assert_contains "$(status_field M delta-size .error)" "unterminated"
assert_exit 2 lmf M apply

# Without the comments the same settings are an ordinary target: the values
# equal the buffer, so the rows are in sync and apply writes epsilon only.
cp "$jsonc_fixtures/commented/comment-like-strings.json" "$delta"
json_edit "$delta" 'data.update({"editor.fontSize": 14, "workbench.colorTheme": "dark", "files.exclude": {"**/.git": True}})'
before=$(sha "$delta")
for id in delta-size delta-theme delta-exclude; do
  assert_eq in-sync "$(state_of M "$id")" "$id"
done
assert_exit 0 lmf M apply
assert_eq "$before" "$(sha "$delta")" "an in-sync JSONC file was rewritten"
assert_eq '"fast"' "$(json_get "$epsilon" mode)"
assert_exit 0 lmf M verify
