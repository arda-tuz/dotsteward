# shellcheck shell=bash
# `dotsteward sync`: evaluates the instance's dotstewardMirrors (stub nix),
# writes every .dotsteward/ mirror byte for byte (only when changed, never
# outside .dotsteward/), removes stale manifest and stage-0 mirrors, refuses
# untracked files before any Nix call, then runs `pins sync` with the same
# flags against the fresh mirrors.
# shellcheck source=tests/engines/pins/check/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/check/helpers.sh"

pins_instance
ds_use_stubs nix
mirror=$inst/.dotsteward/manifest.x86_64-linux.json
mirrors_glob="eval --json --no-update-lock-file $inst#dotstewardMirrors"
pinned_glob="eval --json --no-update-lock-file $inst#lib.pinnedVersions"
stage0=$'DS_STAGE0_SCHEMA_VERSION=1\nDS_STAGE0_PLATFORM=linux\n'

# serve_mirrors MANIFEST_FILE: the stub answers dotstewardMirrors with that
# manifest text and $stage0.
serve_mirrors() {
  jq -n --rawfile manifest "$1" --arg stage0 "$stage0" \
    '{"manifest.x86_64-linux.json": $manifest, "stage0.linux.env": $stage0}' >"$DS_TEST_ROOT/mirrors.json"
  ds_stub_clear_routes nix
  ds_stub_route nix "$mirrors_glob" --stdout-file "$DS_TEST_ROOT/mirrors.json"
  ds_stub_route nix "$pinned_glob" --stdout '{"example-lint":"0.9.0","example-shell":"5.9","example-term":"1.2.0"}'
}

cp "$mirror" "$DS_TEST_ROOT/manifest.json"
serve_mirrors "$DS_TEST_ROOT/manifest.json"

# A stale darwin mirror goes, the launcher stays, the stage-0 mirror is new.
printf '{}\n' >"$inst/.dotsteward/manifest.aarch64-darwin.json"
printf '#!/usr/bin/env bash\n' >"$inst/.dotsteward/cli.sh"
git -C "$inst" add -A
assert_exit 0 dotsteward --instance "$inst" sync
assert_eq "[dotsteward] Removed stale mirror .dotsteward/manifest.aarch64-darwin.json
[dotsteward] Wrote mirror .dotsteward/stage0.linux.env
[pins] Mirrors already in sync; no changes" "$DS_STDOUT"
assert_eq "" "$DS_STDERR"
cmp -s "$mirror" "$DS_TEST_ROOT/manifest.json" || ds_fail "manifest mirror changed"
printf '%s' "$stage0" >"$DS_TEST_ROOT/stage0.expected"
cmp -s "$inst/.dotsteward/stage0.linux.env" "$DS_TEST_ROOT/stage0.expected" || ds_fail "stage-0 mirror bytes differ"
[[ ! -e $inst/.dotsteward/manifest.aarch64-darwin.json ]] || ds_fail "stale mirror kept"
[[ -f $inst/.dotsteward/cli.sh ]] || ds_fail "launcher removed"
assert_call_count 1 nix '*dotstewardMirrors'
assert_call_count 0 nix '*lib.pinnedVersions'

# Current mirrors: nothing is written.
git -C "$inst" add -A
: >"$DS_CALL_LOG"
before=$(stat -c %Y "$mirror")
assert_exit 0 dotsteward --instance "$inst" sync
assert_eq "[dotsteward] Mirrors are current
[pins] Mirrors already in sync; no changes" "$DS_STDOUT"
assert_eq "$before" "$(stat -c %Y "$mirror")"

# A changed manifest is written and pins sync runs against it: a new derive
# rule in the evaluated manifest rewrites its target.
python3 - "$DS_TEST_ROOT/manifest.json" "$DS_TEST_ROOT/manifest.new.json" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
manifest["pins"]["rules"].append(
    {"component": "example-shell", "kind": "derive", "to": "nix_packages.example-shell.notes", "template": "pinned by nixpkgs"}
)
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    handle.write(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY
serve_mirrors "$DS_TEST_ROOT/manifest.new.json"
: >"$DS_CALL_LOG"
assert_exit 0 dotsteward --instance "$inst" sync --nix
assert_eq "[dotsteward] Wrote mirror .dotsteward/manifest.x86_64-linux.json
[pins] Synced files: versions.lock.json" "$DS_STDOUT"
cmp -s "$mirror" "$DS_TEST_ROOT/manifest.new.json" || ds_fail "manifest mirror not written byte for byte"
assert_eq '"pinned by nixpkgs"' "$(json_get "$versions" '.nix_packages."example-shell".notes')"
assert_call_count 1 nix '*dotstewardMirrors'
assert_call_count 1 nix '*lib.pinnedVersions'

# --skill passes through to pins sync.
assert_exit 1 dotsteward --instance "$inst" sync --skill example-missing
assert_contains "$DS_STDERR" "[pins] ERROR: skill not in lock: example-missing"

# A mirror that sync writes for the first time is untracked when pins sync
# --nix runs; it is an output of the evaluation, so it is not refused.
pins_fresh
serve_mirrors "$DS_TEST_ROOT/manifest.json"
: >"$DS_CALL_LOG"
[[ ! -e $inst/.dotsteward/stage0.linux.env ]] || ds_fail "fixture already has a stage-0 mirror"
assert_exit 0 dotsteward --instance "$inst" sync --nix
assert_eq "[dotsteward] Wrote mirror .dotsteward/stage0.linux.env
[pins] Mirrors already in sync; no changes" "$DS_STDOUT"
assert_eq "" "$DS_STDERR"
assert_call_count 1 nix '*dotstewardMirrors'
assert_call_count 1 nix '*lib.pinnedVersions'

# Running sync again (the natural retry) with the mirror still untracked is
# idempotent: sync does not refuse the mirror it wrote itself.
: >"$DS_CALL_LOG"
assert_exit 0 dotsteward --instance "$inst" sync --nix
assert_eq "[dotsteward] Mirrors are current
[pins] Mirrors already in sync; no changes" "$DS_STDOUT"
assert_eq "" "$DS_STDERR"
assert_call_count 1 nix '*dotstewardMirrors'
assert_call_count 1 nix '*lib.pinnedVersions'

# Other untracked files are still refused next to an untracked mirror, by
# sync and by pins --nix, before any Nix call.
printf 'new\n' >"$inst/example-new.txt"
: >"$DS_CALL_LOG"
assert_exit 1 dotsteward --instance "$inst" sync --nix
assert_eq "[dotsteward] ERROR: Nix does not see untracked files; run 'git add -A' first: example-new.txt" "$DS_STDERR"
assert_call_count 0 nix
assert_exit 1 pins sync --nix
assert_eq "[pins] ERROR: Nix does not see untracked files; run 'git add -A' first: example-new.txt" "$DS_STDERR"
assert_call_count 0 nix
rm "$inst/example-new.txt"

# Untracked files: refused before any Nix call.
pins_fresh
serve_mirrors "$DS_TEST_ROOT/manifest.json"
: >"$DS_CALL_LOG"
printf 'new\n' >"$inst/example-new.txt"
assert_exit 1 dotsteward --instance "$inst" sync
assert_eq "[dotsteward] ERROR: Nix does not see untracked files; run 'git add -A' first: example-new.txt" "$DS_STDERR"
assert_call_count 0 nix
rm "$inst/example-new.txt"

# Evaluation failures and unsafe names stop before any write.
ds_stub_clear_routes nix
ds_stub_route nix "$mirrors_glob" --exit 1 --stderr "error: example evaluation failure"
assert_exit 1 dotsteward --instance "$inst" sync
assert_contains "$DS_STDERR" "error: example evaluation failure"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: cannot evaluate the mirrors of the instance"

for name in '../escape.json' 'manifest.x86_64-linux.json.bak' 'notes.txt'; do
  pins_fresh
  jq -n --arg name "$name" '{($name): "x\n"}' >"$DS_TEST_ROOT/bad.json"
  ds_stub_clear_routes nix
  ds_stub_route nix "$mirrors_glob" --stdout-file "$DS_TEST_ROOT/bad.json"
  assert_exit 1 dotsteward --instance "$inst" sync
  assert_eq "[dotsteward] ERROR: unexpected mirror name from dotstewardMirrors: $name" "$DS_STDERR"
  [[ ! -e $inst/escape.json && ! -e $DS_TEST_ROOT/escape.json ]] || ds_fail "wrote outside .dotsteward"
done

assert_exit 0 dotsteward sync --help
assert_contains "$DS_STDOUT" "--nix"
assert_contains "$DS_STDOUT" "--skill"
assert_exit 1 dotsteward --instance "$inst" sync --example-flag
