# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# `dotsteward version`: VERSION, source revision and narHash, from
# a checkout (git), a plain copy (unknown) or a package (baked source-info).
# shellcheck source=tests/skeleton/helpers.sh
source "$DS_REPO_ROOT/tests/skeleton/helpers.sh"

version=$(<"$DS_REPO_ROOT/VERSION")
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || ds_fail "VERSION is not X.Y.Z: [$version]"
assert_eq 1 "$(wc -l <"$DS_REPO_ROOT/VERSION" | tr -d ' ')" "VERSION is one line"

# The real checkout.
assert_exit 0 "$DS_REPO_ROOT/cli/dotsteward" version
assert_eq "dotsteward $version" "$(head -n 1 <<<"$DS_STDOUT")"
[[ $DS_STDOUT =~ ^"dotsteward $version"$'\n'"rev: "[^$'\n']+$'\n'"narHash: "[^$'\n']+$ ]] ||
  ds_fail "version output is not three lines (version, rev, narHash): [$DS_STDOUT]"

# A plain copy outside any repository: rev and narHash are unknown.
plain=$DS_TEST_ROOT/plain
copy_framework "$plain"
assert_exit 0 "$plain/cli/dotsteward" version
assert_eq "dotsteward $version
rev: unknown
narHash: unknown" "$DS_STDOUT"

# A git checkout: rev is HEAD, with -dirty when tracked files changed
# (untracked files do not count, as for Nix flakes).
repo=$DS_TEST_ROOT/repo
copy_framework "$repo"
git -C "$repo" init -q
git -C "$repo" add -A
git -C "$repo" commit -q -m "test: initial"
head=$(git -C "$repo" rev-parse HEAD)
assert_exit 0 "$repo/cli/dotsteward" version
assert_eq "dotsteward $version
rev: $head
narHash: unknown" "$DS_STDOUT"
touch "$repo/untracked"
assert_exit 0 "$repo/cli/dotsteward" version
assert_eq "rev: $head" "$(sed -n 2p <<<"$DS_STDOUT")" "untracked files keep the tree clean"
printf 'changed\n' >>"$repo/tests/run.sh"
assert_exit 0 "$repo/cli/dotsteward" version
assert_eq "rev: $head-dirty" "$(sed -n 2p <<<"$DS_STDOUT")" "a modified tracked file marks the tree dirty"
# Running from another working directory gives the same answer.
# shellcheck disable=SC2016 # expanded by the child shell
assert_exit 0 bash -c 'cd / && "$1" version' bash "$repo/cli/dotsteward"
assert_eq "rev: $head-dirty" "$(sed -n 2p <<<"$DS_STDOUT")" "run from another directory"

# A copy nested inside an unrelated repository does not borrow its revision.
copy_framework "$repo/nested"
assert_exit 0 "$repo/nested/cli/dotsteward" version
assert_eq "rev: unknown" "$(sed -n 2p <<<"$DS_STDOUT")" "nested copy"

# A package: the build bakes rev and narHash into source-info.
pkg=$DS_TEST_ROOT/pkg
copy_framework "$pkg"
rev=$(fake_secret "" 40 hex)
hash="sha256-$(fake_secret "" 43)="
printf 'rev=%s\nnarHash=%s\n' "$rev" "$hash" >"$pkg/source-info"
assert_exit 0 "$pkg/cli/dotsteward" version
assert_eq "dotsteward $version
rev: $rev
narHash: $hash" "$DS_STDOUT"
# A baked dirty revision and a missing narHash (path inputs) are reported as is.
printf 'rev=%s-dirty\n' "$rev" >"$pkg/source-info"
assert_exit 0 "$pkg/cli/dotsteward" version
assert_eq "dotsteward $version
rev: $rev-dirty
narHash: unknown" "$DS_STDOUT"

# A malformed source-info is an error, never printed as is.
for bad in 'rev=abc"def' 'narHash=sha256-a"b' 'rev=ABCDEF0'; do
  printf '%s\n' "$bad" >"$pkg/source-info"
  assert_exit 1 "$pkg/cli/dotsteward" version
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: invalid source-info file" "source-info [$bad]"
  assert_eq "" "$DS_STDOUT" "nothing printed for source-info [$bad]"
done

# Usage.
assert_exit 0 "$plain/cli/dotsteward" version --help
assert_contains "$DS_STDOUT" "Usage: dotsteward version"
assert_exit 1 "$plain/cli/dotsteward" version --bogus
assert_contains "$DS_STDERR" "[dotsteward] ERROR: unknown argument: --bogus"
assert_exit 1 "$plain/cli/dotsteward" version extra
assert_contains "$DS_STDERR" "[dotsteward] ERROR: unknown argument: extra"

# A broken VERSION file is an error, never a guess.
for bad in "1.2" "v1.2.3" "1.2.3 " "1.2.3
1.2.4" ""; do
  printf '%s' "$bad" >"$plain/VERSION"
  assert_exit 1 "$plain/cli/dotsteward" version
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: invalid VERSION file" "VERSION [$bad]"
done
printf '1.2.3\n' >"$plain/VERSION"
assert_exit 0 "$plain/cli/dotsteward" version
assert_eq "dotsteward 1.2.3" "$(head -n 1 <<<"$DS_STDOUT")"
rm "$plain/VERSION"
assert_exit 1 "$plain/cli/dotsteward" version
assert_contains "$DS_STDERR" "[dotsteward] ERROR: missing VERSION file"
