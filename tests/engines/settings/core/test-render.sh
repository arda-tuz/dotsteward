# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and settings_* variables come from the harness and helpers.sh
# Canonical buffer rendering: the header and targets are kept byte for byte,
# entries are written in the fixed field order with one blank line between
# them and table values last, byte for byte like the golden files. A
# canonical buffer is a fixed point of track and
# untrack, and commands that change nothing never rewrite it.
# shellcheck source=tests/engines/settings/core/helpers.sh
source "$DS_REPO_ROOT/tests/engines/settings/core/helpers.sh"

round_trip() {
  local machine=$1
  lmf "$machine" track --id render-probe --target "$2" --key probe >/dev/null
  lmf "$machine" untrack render-probe >/dev/null
}

# The fixture buffer (in the canonical layout) is a fixed point.
settings_machines
buffer=$settings_work/A/repo/local-maintained-files/buffer.toml
round_trip A alpha
cmp -s "$buffer" "$settings_fixtures/buffer/buffer.toml" ||
  ds_fail "track and untrack changed the buffer: $(diff "$settings_fixtures/buffer/buffer.toml" "$buffer")"
# Commands with nothing to write leave the file untouched (same inode and
# modification time).
touch -d '2001-01-01 00:00:00' "$buffer"
stamp=$(stat -c '%i %Y' "$buffer")
for command in apply reconcile flush verify status; do
  assert_exit 0 lmf A "$command"
done
assert_eq "$stamp" "$(stat -c '%i %Y' "$buffer")" "a command without changes rewrote the buffer"

# A hand-written buffer is rendered canonically on the next save; the
# result equals the golden rendering and is itself a fixed point.
mkdir -p "$DS_TEST_ROOT/messy"
cp "$settings_fixtures/render/messy.toml" "$DS_TEST_ROOT/messy/buffer.toml"
cp -R "$settings_fixtures/render/files" "$DS_TEST_ROOT/messy/files"
settings_repo "$settings_work/R/repo" "$DS_TEST_ROOT/messy"
mkdir -p "$settings_work/R/home"
round_trip R beta
messy=$settings_work/R/repo/local-maintained-files/buffer.toml
cmp -s "$messy" "$settings_fixtures/render/canonical.toml" ||
  ds_fail "canonical rendering differs: $(diff "$settings_fixtures/render/canonical.toml" "$messy")"
round_trip R alpha
cmp -s "$messy" "$settings_fixtures/render/canonical.toml" || ds_fail "the canonical buffer is not a fixed point"

# A tracked table value is written as an [entries.value] table after the
# scalar fields.
mkdir -p "$settings_work/R/home/.config/beta"
printf '[look]\ncolor = "blue"\n\n[look.font]\nsize = 12\n' >"$settings_work/R/home/.config/beta/config.toml"
assert_exit 0 lmf R track --id beta-look --target beta --key look --note "look and feel"
expected='[[entries]]
id = "beta-look"
target = "beta"
key = ["look"]
note = "look and feel"

[entries.value]
color = "blue"

[entries.value.font]
size = 12'
assert_eq "$(cat "$settings_fixtures/render/canonical.toml")"$'\n\n'"$expected" "$(cat "$messy")"
