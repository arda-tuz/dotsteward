# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and settings_* variables come from the harness and helpers.sh
# The robustness fixes of the port, each a crash or a misleading message of
# the original engine: a target that is not UTF-8 (or not readable) is an
# error row, a corrupt base.json exits 2 with a message, the first-contact
# warning names a backup only when one was taken, and untrack works on an
# invalid buffer, touching only the named entry.
# shellcheck source=tests/engines/settings/core/helpers.sh
source "$DS_REPO_ROOT/tests/engines/settings/core/helpers.sh"

settings_repo "$settings_work/A/repo"
a_home=$settings_work/A/home
alpha=$a_home/.config/alpha/settings.json
beta=$a_home/.config/beta/config.toml
mkdir -p "$(dirname "$alpha")"

# A target that is not UTF-8: its rows are errors, the other rows are
# evaluated, and apply refuses before writing anything.
printf '{"statusLine": "\xff\xfe"}\n' >"$alpha"
before=$(sha "$alpha")
assert_exit 0 lmf A status
assert_eq error "$(state_of A alpha-status)"
assert_contains "$(status_field A alpha-env-model .error)" "UTF-8"
assert_contains "$(status_field A alpha-env-model .error)" "$alpha"
assert_eq first-contact "$(state_of A beta-threads)"
assert_exit 2 lmf A apply
assert_contains "$DS_STDERR" "alpha-status"
assert_eq "$before" "$(sha "$alpha")"
[[ ! -e $beta ]] || ds_fail "apply wrote another target despite error rows"
assert_exit 1 lmf A verify
rm "$alpha"

# An unreadable target is an error row too (not meaningful as root).
if [[ $(id -u) != 0 ]]; then
  printf '{}\n' >"$alpha"
  chmod 0000 "$alpha"
  assert_eq error "$(state_of A alpha-status)"
  assert_exit 2 lmf A apply
  chmod 0644 "$alpha"
  rm "$alpha"
fi

# A buffer that is not UTF-8 is an error of the command.
buffer=$settings_work/A/repo/local-maintained-files/buffer.toml
cp "$buffer" "$DS_TEST_ROOT/buffer.good"
printf '# \xff\n' >>"$buffer"
assert_exit 2 lmf A status
assert_contains "$DS_STDERR" "buffer.toml"
cp "$DS_TEST_ROOT/buffer.good" "$buffer"

# A corrupt base.json: exit 2 with a message naming it, for every command;
# the file is left as it was.
state=$settings_work/A/state
mkdir -p "$state"
for content in '{"schema_version": 1, "entries": ' '[1, 2]' '{"schema_version": 1, "entries": []}' \
  '{"schema_version": 1, "entries": {"alpha|[\"x\"]": {"sha256": "abc"}}}' \
  '{"schema_version": 7, "entries": {}}'; do
  printf '%s\n' "$content" >"$state/base.json"
  for command in status apply reconcile verify; do
    assert_exit 2 lmf A "$command"
    assert_contains "$DS_STDERR" "base.json"
  done
  assert_eq "$content" "$(cat "$state/base.json")"
done
rm "$state/base.json"

# The first-contact warning names the backup when one was taken (alpha) and
# no backup at all for a backup = false target (gamma).
printf '{\n  "env": {\n    "DEFAULT_MODEL": "large"\n  }\n}\n' >"$alpha"
printf '{"guideline": "long"}\n' >"$a_home/.gamma.json"
assert_exit 0 lmf A apply
alpha_warning=$(grep 'alpha-env-model' <<<"$DS_STDERR")
gamma_warning=$(grep 'gamma-guideline' <<<"$DS_STDERR")
backup=$(find "$state/backups" -type f -name settings.json)
[[ -n $backup ]] || ds_fail "no backup of the alpha settings"
assert_contains "$alpha_warning" "$backup"
assert_contains "$gamma_warning" '"long"'
assert_not_contains "$gamma_warning" "backup"
assert_eq '"short"' "$(json_get "$a_home/.gamma.json" guideline)"

# untrack on an invalid buffer: only the named entry goes; the other
# entries, including invalid ones and their unknown fields, stay.
cp "$DS_TEST_ROOT/buffer.good" "$buffer"
cat >>"$buffer" <<'EOF'

[[entries]]
id = "broken"
target = "no-such-target"
key = ["x"]
value = 1

[[entries]]
id = "colour"
target = "alpha"
key = ["colour"]
value = "red"
colour = "unknown field"

[[entries]]
id = "evil"
kind = "file"
path = "~/x"
source = "../../../victim"
EOF
# files/../../../victim resolves to the machine directory.
printf 'keep me\n' >"$settings_work/A/victim"
assert_exit 2 lmf A status
assert_exit 0 lmf A untrack broken
buffer_has "$settings_work/A/repo" broken && ds_fail "untrack left the broken entry"
grep -Fq 'colour = "unknown field"' "$buffer" || ds_fail "untrack dropped a field of another entry"
assert_exit 2 lmf A status
assert_exit 0 lmf A untrack evil
[[ -f $settings_work/A/victim ]] || ds_fail "untrack deleted a file outside files/"
assert_exit 0 lmf A untrack colour
cmp -s "$buffer" "$DS_TEST_ROOT/buffer.good" || ds_fail "untrack changed other entries: $(diff "$DS_TEST_ROOT/buffer.good" "$buffer")"
assert_exit 0 lmf A status
# An unknown id on an invalid buffer is still an error, and a buffer that is
# not TOML cannot be edited at all.
printf '[[entries]]\nid = "broken"\n' >>"$buffer"
assert_exit 2 lmf A untrack no-such-id
assert_contains "$DS_STDERR" "no-such-id"
printf 'not = = toml\n' >>"$buffer"
assert_exit 2 lmf A untrack broken
