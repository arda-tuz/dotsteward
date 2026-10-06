# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and settings_* variables come from the harness and helpers.sh
# A comment-free JSONC target on two machines: apply creates a missing file
# (indent 2, create_mode), merges the tracked keys into an existing file
# keeping the key order, the untracked keys, the comment-like strings and
# the missing trailing newline, flush and track read it like JSON, and a
# published change reaches the other machine with its trailing newline.
# shellcheck source=tests/engines/settings/core/helpers.sh
source "$DS_REPO_ROOT/tests/engines/settings/core/helpers.sh"

jsonc_fixtures=$DS_REPO_ROOT/tests/engines/settings/jsonc/fixtures
settings_machines "$jsonc_fixtures/buffer"
a_delta=$settings_work/A/home/.config/delta/settings.json
b_delta=$settings_work/B/home/.config/delta/settings.json

# Machine A has no settings file yet: apply creates it.
assert_exit 0 lmf A apply
cmp -s "$jsonc_fixtures/golden/delta-created.json" "$a_delta" ||
  ds_fail "created JSONC file differs: $(diff "$jsonc_fixtures/golden/delta-created.json" "$a_delta")"
assert_file_mode "$a_delta" 0644
assert_exit 0 lmf A verify

# Machine B has its own comment-free file without a trailing newline: the
# first contact writes the repository values in place and appends the new
# key; everything else stays byte for byte in JSON form.
mkdir -p "$(dirname "$b_delta")"
cp "$jsonc_fixtures/commented/comment-like-strings.json" "$b_delta"
assert_eq first-contact "$(state_of B delta-size)"
assert_eq first-contact "$(state_of B delta-exclude)"
assert_exit 0 lmf B apply
cmp -s "$jsonc_fixtures/golden/delta-merged.json" "$b_delta" ||
  ds_fail "merged JSONC file differs: $(diff "$jsonc_fixtures/golden/delta-merged.json" "$b_delta")"
assert_exit 0 lmf B verify

# A local change on B is flushed like JSON, and a new key is tracked from
# the JSONC file (a dotted key needs --key-json).
NO_NEWLINE=1 json_edit "$b_delta" 'data["workbench.colorTheme"] = "solarized"'
assert_eq local-changed "$(state_of B delta-theme)"
assert_exit 0 lmf B flush
assert_eq '"solarized"' "$(buffer_get B delta-theme)"
assert_exit 0 lmf B track --id delta-proxy --target delta --key-json '["http.proxy"]'
assert_eq '"http://proxy.example.invalid:8080"' "$(buffer_get B delta-proxy)"
assert_exit 0 lmf B validate
publish B
[[ $(tail -c 1 "$b_delta") == "}" ]] || ds_fail "the trailing newline appeared on B"

# A receives both: the changed theme and the newly tracked key, keeping its
# trailing newline.
pull A
assert_eq remote-changed "$(state_of A delta-theme)"
assert_eq first-contact "$(state_of A delta-proxy)"
assert_exit 0 lmf A apply
python3 - "$a_delta" <<'PY' || ds_fail "A's settings file is not the expected JSON"
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    text = handle.read()
assert text.endswith("}\n"), repr(text[-5:])
expected = {
    "editor.fontSize": 14,
    "workbench.colorTheme": "solarized",
    "files.exclude": {"**/.git": True},
    "http.proxy": "http://proxy.example.invalid:8080",
}
assert text == json.dumps(expected, indent=2) + "\n", text
PY
assert_exit 0 lmf A verify
