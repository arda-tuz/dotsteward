# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and settings_* variables come from the harness and helpers.sh
# Machine state: base.json written in the original engine's exact format
# and an existing one used unmodified, the backup layout (one UTC root per
# run, absolute-path mirror, 0700 directories, 0600 files, pre-change
# content, nothing for backup = false targets), the journal (apply and
# resolve only, old and new values) and the blocking lock.
# shellcheck source=tests/engines/settings/core/helpers.sh
source "$DS_REPO_ROOT/tests/engines/settings/core/helpers.sh"

settings_machines
a_state=$settings_work/A/state
b_home=$settings_work/B/home
b_state=$settings_work/B/state

# A fresh apply with a published buffer writes base.json byte for byte like
# the original engine did for the same buffer.
assert_exit 0 lmf A apply
cmp -s "$a_state/base.json" "$settings_fixtures/legacy-state/base.json" ||
  ds_fail "base.json differs from the original engine's: $(diff "$settings_fixtures/legacy-state/base.json" "$a_state/base.json")"
assert_file_mode "$a_state" 0700
assert_file_mode "$a_state/base.json" 0600
assert_file_mode "$a_state/journal.jsonl" 0600
[[ ! -e $a_state/backups ]] || ds_fail "a fresh apply into an empty home took backups"

# An existing base.json from the original engine is used as is: every entry
# is in sync and no command rewrites it.
legacy=$settings_work/legacy-state
mkdir -p "$legacy"
cp "$settings_fixtures/legacy-state/base.json" "$legacy/base.json"
chmod 0600 "$legacy/base.json"
before=$(sha "$legacy/base.json")
assert_json - '[.entries[] | select(.id != "gamma-guideline") | .state] | unique == ["in-sync"]' \
  <<<"$(lmf A --state-dir "$legacy" status --json)"
assert_json - '[.entries[] | select(.id != "gamma-guideline") | .base != null] | all' \
  <<<"$(lmf A --state-dir "$legacy" status --json)"
assert_exit 0 lmf A --state-dir "$legacy" reconcile
assert_exit 0 lmf A --state-dir "$legacy" apply
assert_exit 0 lmf A --state-dir "$legacy" verify
assert_eq "$before" "$(sha "$legacy/base.json")"
[[ ! -e $legacy/journal.jsonl ]] || ds_fail "a no-op apply journaled"

# Backups: machine B already has its own files. One apply backs up every
# changed file once under one root, mirroring the absolute path, with the
# content from before the change; the backup = false target is never copied.
mkdir -p "$b_home/.config/alpha" "$b_home/.config/beta"
printf '{\n  "own": true\n}\n' >"$b_home/.config/alpha/settings.json"
printf 'own = true\n' >"$b_home/.config/beta/config.toml"
printf '#!/bin/sh\necho own\n' >"$b_home/.config/alpha/status.sh"
printf '{"account": "kept"}\n' >"$b_home/.gamma.json"
cp -R "$b_home" "$DS_TEST_ROOT/b-home-before"
assert_exit 0 lmf B apply
roots=("$b_state"/backups/*)
assert_eq 1 "${#roots[@]}" "one backup root per run"
[[ $(basename "${roots[0]}") =~ ^[0-9]{8}T[0-9]{12}Z$ ]] || ds_fail "unexpected backup root name: ${roots[0]}"
assert_file_mode "$b_state/backups" 0700
for rel in .config/alpha/settings.json .config/beta/config.toml .config/alpha/status.sh; do
  copy=${roots[0]}/${b_home#/}/$rel
  [[ -f $copy ]] || ds_fail "no backup of $rel at $copy"
  cmp -s "$copy" "$DS_TEST_ROOT/b-home-before/$rel" || ds_fail "the backup of $rel is not the pre-change content"
  assert_file_mode "$copy" 0600
done
[[ -z $(find "$b_state/backups" -name .gamma.json) ]] || ds_fail "a backup = false target was copied"
assert_json "$b_home/.gamma.json" '. == {"account": "kept", "guideline": "short"}'

# The journal holds one record per live write with old and new values.
journal=$b_state/journal.jsonl
assert_json - 'map(.command) | unique == ["apply"]' <<<"$(jq -s . "$journal")"
assert_json - 'map(select(.id == "beta-threads"))[0] | .identity == "beta|[\"agents\", \"max_threads\"]" and .old == {"absent": true} and .new == {"value": 10} and (.time | test("^[0-9-]{10}T[0-9:]{8}Z$"))' \
  <<<"$(jq -s . "$journal")"
assert_json - 'map(select(.id == "alpha-script"))[0] | .identity == "file|~/.config/alpha/status.sh" and (.old.sha256 | length) == 64 and .new.mode == "0755"' \
  <<<"$(jq -s . "$journal")"
assert_exit 0 lmf B reconcile

# flush never journals; resolve --remote does; a later run uses a new root.
assert_exit 0 lmf A reconcile
set_line "$settings_work/A/home/.config/beta/config.toml" 'max_threads = .*' 'max_threads = 11'
a_lines=$(wc -l <"$a_state/journal.jsonl")
assert_exit 0 lmf A flush
assert_eq "$a_lines" "$(wc -l <"$a_state/journal.jsonl")" "flush journaled"
publish A
set_line "$b_home/.config/beta/config.toml" 'max_threads = .*' 'max_threads = 12'
pull B
assert_eq conflict "$(state_of B beta-threads)"
sleep 0.01
assert_exit 0 lmf B resolve beta-threads --remote
assert_json - '.[-1] | .command == "resolve" and .old == {"value": 12} and .new == {"value": 11}' \
  <<<"$(jq -s . "$journal")"
roots=("$b_state"/backups/*)
assert_eq 2 "${#roots[@]}" "a second run takes a second backup root"
copy=${roots[1]}/${b_home#/}/.config/beta/config.toml
assert_eq 12 "$(toml_get "$copy" agents.max_threads)"

# The lock: a command waits while another process holds the state lock.
holder_ready=$DS_TEST_ROOT/holder-ready
release=$DS_TEST_ROOT/release
# shellcheck disable=SC2016 # the script is expanded by the child bash
flock -x "$b_state/lock" bash -c 'touch "$1"; while [[ ! -e $2 ]]; do sleep 0.1; done' \
  bash "$holder_ready" "$release" &
holder=$!
ds_defer kill "$holder"
for _ in $(seq 100); do
  [[ -e $holder_ready ]] && break
  sleep 0.1
done
[[ -e $holder_ready ]] || ds_fail "the lock holder did not start"
lmf B status --json >"$DS_TEST_ROOT/waiting.json" &
waiting=$!
sleep 1
kill -0 "$waiting" 2>/dev/null || ds_fail "the command did not wait for the lock"
[[ ! -s $DS_TEST_ROOT/waiting.json ]] || ds_fail "the command ran while the lock was held"
touch "$release"
wait "$holder"
wait "$waiting" || ds_fail "the waiting command failed after the lock was released"
assert_json "$DS_TEST_ROOT/waiting.json" '.schema_version == 1'
