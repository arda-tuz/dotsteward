# shellcheck shell=bash
# `pins check --nix` and `pins sync --nix` (nix-resolved): the resolved
# versions against `nix eval --json --no-update-lock-file <instance>#
# lib.pinnedVersions` (stub nix; with DOTSTEWARD_FRAMEWORK_OVERRIDE also
# `--override-input dotsteward REF --no-write-lock-file`), key set and value
# mismatches, untracked files refused before any Nix call, evaluation
# failures as exit 2, and sync writing resolved versions (and their
# skills-lock mirrors) without creating entries or touching flake.lock.
# shellcheck source=tests/engines/pins/check/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/check/helpers.sh"

pins_instance
ds_use_stubs nix
E='[pins] ERROR: '
eval_glob="eval --json --no-update-lock-file $inst#lib.pinnedVersions"

pinned() {
  ds_stub_clear_routes nix
  ds_stub_route nix "$eval_glob" --stdout "$1"
}

assert_exit 0 pins check
plain=$(check_count)

pinned '{"example-lint":"0.9.0","example-shell":"5.9","example-term":"1.2.0"}'
lock_sha=$(sha256sum "$inst/flake.lock")
assert_exit 0 pins check --nix
with_nix=$(check_count)
((with_nix == plain + 4)) || ds_fail "--nix should add 4 checks: $plain -> $with_nix"
assert_call_count 1 nix '*lib.pinnedVersions'
assert_eq "$(printf 'nix %q %q %q %q %q %q' --extra-experimental-features 'nix-command flakes' \
  eval --json --no-update-lock-file "$inst#lib.pinnedVersions")" "$(ds_calls_of nix)"
assert_eq "$lock_sha" "$(sha256sum "$inst/flake.lock")" "flake.lock changed"

# A framework override (DOTSTEWARD_FRAMEWORK_OVERRIDE, which the gate sets
# for its steps) replaces the dotsteward input in memory; an empty value is
# no override.
ds_stub_clear_routes nix
ds_stub_route nix "$eval_glob --override-input dotsteward path:/srv/dotsteward --no-write-lock-file" \
  --stdout '{"example-lint":"0.9.0","example-shell":"5.9","example-term":"1.2.0"}'
: >"$DS_CALL_LOG"
assert_exit 0 env DOTSTEWARD_FRAMEWORK_OVERRIDE=path:/srv/dotsteward \
  "$DS_REPO_ROOT/cli/dotsteward" --instance "$inst" pins check --nix
assert_eq "$(printf 'nix %q %q %q %q %q %q %q %q %q %q' --extra-experimental-features 'nix-command flakes' \
  eval --json --no-update-lock-file "$inst#lib.pinnedVersions" \
  --override-input dotsteward path:/srv/dotsteward --no-write-lock-file)" "$(ds_calls_of nix)"
assert_eq "$lock_sha" "$(sha256sum "$inst/flake.lock")" "flake.lock changed"
pinned '{"example-lint":"0.9.0","example-shell":"5.9","example-term":"1.2.0"}'
: >"$DS_CALL_LOG"
assert_exit 0 env DOTSTEWARD_FRAMEWORK_OVERRIDE= "$DS_REPO_ROOT/cli/dotsteward" --instance "$inst" pins check --nix
assert_call_count 0 nix '*--override-input*'

pinned '{"example-lint":"0.9.0","example-new":"1.0","example-term":"1.2.0"}'
check_fails_nix() {
  local count=$1 line noun=inconsistencies
  shift
  assert_exit 1 pins check --nix
  for line in "$@"; do
    assert_contains "$DS_STDERR" "$line"$'\n'
  done
  ((count == 1)) && noun=inconsistency
  assert_contains "$DS_STDERR" "[pins] $count $noun; "
  assert_eq "$count" "$(grep -c '^\[pins\] ERROR: ' <<<"$DS_STDERR")" "number of failure lines"
}
check_fails_nix 2 \
  "${E}lib.pinnedVersions keys: expected ['example-lint', 'example-shell', 'example-term'], found ['example-lint', 'example-new', 'example-term']" \
  "${E}nix_packages.example-new.resolved (Nix evaluation): expected '1.0', found None"

pinned '{"example-lint":"0.9.0","example-shell":"5.9.1","example-term":"1.2.0"}'
check_fails_nix 1 "${E}nix_packages.example-shell.resolved (Nix evaluation): expected '5.9.1', found '5.9'"

# Untracked, not ignored files: refused before any Nix call.
: >"$DS_CALL_LOG"
printf 'scratch\n' >"$inst/example untracked.txt"
printf 'ignored.txt\n' >"$inst/.git/info/exclude"
printf 'ignored\n' >"$inst/ignored.txt"
assert_exit 1 pins check --nix
assert_eq "${E}Nix does not see untracked files; run 'git add -A' first: example untracked.txt" "$DS_STDERR"
assert_exit 1 pins sync --nix
assert_eq "${E}Nix does not see untracked files; run 'git add -A' first: example untracked.txt" "$DS_STDERR"
assert_call_count 0 nix
rm "$inst/example untracked.txt"

# Evaluation failures and unusable output: exit 2 with the cause.
ds_stub_clear_routes nix
ds_stub_route nix "$eval_glob" --exit 1 --stderr "error: example evaluation failure"
assert_exit 2 pins check --nix
assert_contains "$DS_STDERR" "${E}nix eval of lib.pinnedVersions failed"
assert_contains "$DS_STDERR" "error: example evaluation failure"
assert_not_contains "$DS_STDERR" "Traceback"
pinned 'not json'
assert_exit 2 pins check --nix
assert_contains "$DS_STDERR" "${E}nix eval of lib.pinnedVersions printed invalid JSON"
pinned '["example-lint"]'
assert_exit 2 pins check --nix
assert_contains "$DS_STDERR" "${E}nix eval of lib.pinnedVersions: expected an object of strings"

# sync --nix writes resolved versions, then their mirrors (here the skills
# lock nix_tools), and creates nothing for names the lock does not have.
pins_fresh
pinned '{"example-lint":"0.9.0","example-new":"1.0","example-shell":"5.9.1","example-term":"1.2.1"}'
assert_exit 0 pins sync --nix
assert_eq "[pins] Synced files: versions.lock.json, agent/skills.lock.json" "$DS_STDOUT"
assert_eq '"5.9.1"' "$(json_get "$versions" '.nix_packages."example-shell".resolved')"
assert_eq '"1.2.1"' "$(json_get "$versions" '.nix_packages."example-term".resolved')"
assert_eq '"1.2.1"' "$(json_get "$skills" '.nix_tools."example-term"')"
assert_eq 'false' "$(json_get "$versions" '.nix_packages | has("example-new")')"
assert_eq "$lock_sha" "$(sha256sum "$inst/flake.lock")" "flake.lock changed"
# Plain sync leaves resolved versions alone.
assert_exit 0 pins sync
assert_eq "[pins] Mirrors already in sync; no changes" "$DS_STDOUT"
assert_eq '"5.9.1"' "$(json_get "$versions" '.nix_packages."example-shell".resolved')"
