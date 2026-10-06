# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# `dotsteward version --json`: the version, source revision and narHash as
# one JSON object (2-space pretty, printed without jq), with null for an
# unknown value, from a checkout (git), a plain copy and a package (baked
# source-info). The first change published through `dotsteward contribute`.
# shellcheck source=tests/skeleton/helpers.sh
source "$DS_REPO_ROOT/tests/skeleton/helpers.sh"

version=$(<"$DS_REPO_ROOT/VERSION")

# json_of OUTPUT: OUTPUT is one JSON object with exactly the keys version,
# rev and narHash; prints it compact with sorted keys.
json_of() {
  local output=$1
  jq -e 'type == "object" and (keys == ["narHash", "rev", "version"])' <<<"$output" >/dev/null ||
    ds_fail "version --json is not an object with version, rev and narHash: [$output]"
  jq -cS . <<<"$output"
}

# The real checkout: the version is the VERSION file, rev is a git revision.
assert_exit 0 "$DS_REPO_ROOT/cli/dotsteward" version --json
json_of "$DS_STDOUT" >/dev/null
assert_eq "$version" "$(jq -r .version <<<"$DS_STDOUT")" "version is the VERSION file"
[[ $(jq -r .rev <<<"$DS_STDOUT") =~ ^[0-9a-f]{40}(-dirty)?$|^null$ ]] ||
  ds_fail "rev is not a git revision or null: [$DS_STDOUT]"
assert_eq "" "$DS_STDERR" "nothing on stderr"

# A plain copy outside any repository: rev and narHash are null.
plain=$DS_TEST_ROOT/plain
copy_framework "$plain"
assert_exit 0 "$plain/cli/dotsteward" version --json
assert_eq "{
  \"version\": \"$version\",
  \"rev\": null,
  \"narHash\": null
}" "$DS_STDOUT" "plain copy: exact 2-space pretty output"

# A git checkout: rev is HEAD, with -dirty when tracked files changed.
repo=$DS_TEST_ROOT/repo
copy_framework "$repo"
git -C "$repo" init -q
git -C "$repo" add -A
git -C "$repo" commit -q -m "test: initial"
head=$(git -C "$repo" rev-parse HEAD)
assert_exit 0 "$repo/cli/dotsteward" version --json
assert_eq "{\"narHash\":null,\"rev\":\"$head\",\"version\":\"$version\"}" "$(json_of "$DS_STDOUT")" "checkout"
printf 'changed\n' >>"$repo/tests/run.sh"
assert_exit 0 "$repo/cli/dotsteward" version --json
assert_eq "$head-dirty" "$(jq -r .rev <<<"$DS_STDOUT")" "a modified tracked file marks the tree dirty"

# A package: the build bakes rev and narHash into source-info.
pkg=$DS_TEST_ROOT/pkg
copy_framework "$pkg"
rev=$(fake_secret "" 40 hex)
hash="sha256-$(fake_secret "" 43)="
printf 'rev=%s\nnarHash=%s\n' "$rev" "$hash" >"$pkg/source-info"
assert_exit 0 "$pkg/cli/dotsteward" version --json
assert_eq "{
  \"version\": \"$version\",
  \"rev\": \"$rev\",
  \"narHash\": \"$hash\"
}" "$DS_STDOUT" "package"
# The text output is unchanged without --json.
assert_exit 0 "$pkg/cli/dotsteward" version
assert_eq "dotsteward $version
rev: $rev
narHash: $hash" "$DS_STDOUT" "text output"

# Errors stay errors with --json: nothing on stdout.
printf 'rev=ABCDEF0\n' >"$pkg/source-info"
assert_exit 1 "$pkg/cli/dotsteward" version --json
assert_contains "$DS_STDERR" "[dotsteward] ERROR: invalid source-info file"
assert_eq "" "$DS_STDOUT" "nothing printed for a malformed source-info"
printf '1.2\n' >"$plain/VERSION"
assert_exit 1 "$plain/cli/dotsteward" version --json
assert_contains "$DS_STDERR" "[dotsteward] ERROR: invalid VERSION file"
assert_eq "" "$DS_STDOUT" "nothing printed for a broken VERSION"
printf '%s\n' "$version" >"$plain/VERSION"

# Usage: --help documents --json; other arguments are still refused.
assert_exit 0 "$plain/cli/dotsteward" version --help
assert_contains "$DS_STDOUT" "Usage: dotsteward version [--json]"
for args in "--json --bogus" "--bogus --json" "--json extra" "--json --json"; do
  # shellcheck disable=SC2086 # word splitting is the point
  assert_exit 1 "$plain/cli/dotsteward" version $args
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: " "version $args"
  assert_eq "" "$DS_STDOUT" "nothing printed for version $args"
done
