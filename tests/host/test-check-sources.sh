# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Each framework check depends on the files of its source set, the file set
# that nix/check-sources.nix gives it, and on no other file of the tree:
# - a commit that changes only files outside the set of a check leaves the
#   check's derivation as it was: a fix of a README, of the documentation or
#   of one suite rebuilds only the checks whose sets hold the changed files;
# - one changed file of every set changes every check;
# - a release commit (VERSION and the files that carry the version string)
#   changes only the checks whose sets hold one of those files;
# - every file of the tree is in the set of a check (the whole-tree checks
#   count with the files they test themselves, not with the tree they scan)
#   or in one of the readable lists of files that no check tests
#   (untested) or that only the flake evaluation reads (evaluated), so a
#   new file or directory cannot escape every check unseen.
#
# Real Nix evaluates the checks of a git repository that holds the tree of
# the checkout under test (its tracked and untracked files that git does
# not ignore), so this test runs on the host, like every test of
# tests/host, and never in the build sandbox, which has no Nix daemon.

command -v nix >/dev/null 2>&1 || ds_fail "this test needs nix on PATH"
git -C "$DS_REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  ds_fail "this test needs a git checkout of the framework: $DS_REPO_ROOT"

nix_flakes() {
  nix --extra-experimental-features 'nix-command flakes' "$@"
}

# --- the tree under test as a repository of its own ---------------------------

repo=$DS_TEST_ROOT/framework
list=$DS_TEST_ROOT/files
mkdir -p "$repo"
while IFS= read -r -d '' path; do
  if [[ -e $DS_REPO_ROOT/$path || -L $DS_REPO_ROOT/$path ]]; then
    printf '%s\0' "$path"
  fi
done < <(git -C "$DS_REPO_ROOT" ls-files -z --cached --others --exclude-standard) >"$list"
tar -C "$DS_REPO_ROOT" --null -T "$list" -cf - | tar -C "$repo" -xf -
git -C "$repo" init -q
git -C "$repo" add -A
git -C "$repo" commit -q -m "test: the framework tree"

# checks_of REV FILE: {name: drvPath} of checks.x86_64-linux at commit REV.
checks_of() {
  nix_flakes eval --json "git+file://$repo?rev=$1#checks.x86_64-linux" \
    --apply 'checks: builtins.mapAttrs (name: check: check.drvPath) checks' >"$2" ||
    ds_fail "the checks of '$(git -C "$repo" log -1 --format=%s "$1")' do not evaluate"
}

# checks_of_pair REV FILE REV FILE: both at once. An evaluation takes a
# minute of one core and over 2 GiB, so two at a time halve this test's
# time, and more would crowd the memory of a small machine.
checks_of_pair() {
  local first second
  checks_of "$1" "$2" &
  first=$!
  checks_of "$3" "$4" &
  second=$!
  wait "$first" || ds_fail "the checks of $1 do not evaluate"
  wait "$second" || ds_fail "the checks of $3 do not evaluate"
}

# changed A B: the checks whose derivation differs between the files A and B.
changed() {
  jq -rn --slurpfile a "$1" --slurpfile b "$2" \
    '[($a[0] | keys) + ($b[0] | keys) | unique[] | select($a[0][.] != $b[0][.])] | join(" ")'
}

# extend FILE...: one more line at the end of each file of the tree.
extend() {
  local file
  for file in "$@"; do
    [[ -f $repo/$file ]] || ds_fail "the tree has no file $file"
    printf '\n' >>"$repo/$file"
  done
}

# commit SUBJECT: commits every change of the tree, and prints the commit.
commit() {
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$1"
  git -C "$repo" rev-parse HEAD
}

# --- the commits ------------------------------------------------------------------

base_rev=$(git -C "$repo" rev-parse HEAD)
count=$(find "$repo/nix/checks" -maxdepth 1 -type f -name '*.nix' | wc -l)

# A fix of the documentation and of one suite: files outside the sets of most
# checks, since a file that is in a check's set would hide that the check
# also depends on the others.
docs=(
  README.md
  docs/testing.md
  modules/components/shell/README.md
  tests/cli/gate/helpers.sh
  tests/vm/README.md
)
extend "${docs[@]}"
docs_rev=$(commit "test: documentation and one suite")

# The source sets, from the map of the tree under test.
sources=$DS_TEST_ROOT/sources.json
[[ -f $repo/nix/check-sources.nix ]] || ds_fail "the checks have no source sets (nix/check-sources.nix)"
nix_flakes eval --json --expr "
  let flake = builtins.getFlake \"git+file://$repo?rev=$base_rev\";
  in (import (flake.outPath + \"/nix/check-sources.nix\") { inherit (flake.inputs.nixpkgs) lib; }).report" \
  >"$sources" || ds_fail "nix/check-sources.nix does not evaluate"

# A release.
version=$(<"$repo/VERSION")
[[ $version =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || ds_fail "unexpected VERSION [$version]"
next=${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))
release=(
  VERSION
  template/flake.nix
  .claude-plugin/marketplace.json
  plugins/dotsteward/.claude-plugin/plugin.json
  plugins/dotsteward/.codex-plugin/plugin.json
)
for file in "${release[@]}"; do
  grep -qF "$version" "$repo/$file" || ds_fail "$file does not carry the version $version"
  sed -i "s/${version//./\\.}/$next/g" "$repo/$file"
done
release_rev=$(commit "test: release $next")

# One file of every set: a file of each set that the evaluation reads as data
# never takes an extra line; VERSION is the only one whose format would break.
mapfile -t touched < <(jq -r '[.sources[] | map(select(. != "VERSION"))[0] | values] | unique[]' "$sources")
extend "${touched[@]}"
every_rev=$(commit "test: one file of every set")

checks_of_pair "$base_rev" "$DS_TEST_ROOT/base.json" "$docs_rev" "$DS_TEST_ROOT/docs.json"
checks_of_pair "$release_rev" "$DS_TEST_ROOT/release.json" "$every_rev" "$DS_TEST_ROOT/every.json"

assert_eq "$((count))" "$(jq length "$DS_TEST_ROOT/base.json")" "every check evaluated"
assert_eq "$(jq -r '.sources | keys | join(" ")' "$sources")" "$(jq -r 'keys | join(" ")' "$DS_TEST_ROOT/base.json")" \
  "the checks with a source set"

# predicted FILE...: the checks whose source set holds one of FILE.
predicted() {
  jq -r '[.sources | to_entries[] | select(any(.value[]; IN($ARGS.positional[]))) | .key] | join(" ")' \
    --args "$@" <"$sources"
}

# --- what each commit rebuilds ------------------------------------------------------

rebuilt=$(changed "$DS_TEST_ROOT/base.json" "$DS_TEST_ROOT/docs.json")
assert_eq "$(predicted "${docs[@]}")" "$rebuilt" "the checks rebuilt for a commit to ${docs[*]}"

rebuilt=$(changed "$DS_TEST_ROOT/docs.json" "$DS_TEST_ROOT/release.json")
assert_eq "$(predicted "${release[@]}")" "$rebuilt" "the checks rebuilt for the release commit"

rebuilt=$(changed "$DS_TEST_ROOT/release.json" "$DS_TEST_ROOT/every.json")
assert_eq "$(predicted "${touched[@]}")" "$rebuilt" "the checks rebuilt for one file of every set"
assert_eq "$(jq -r '[.sources | to_entries[] | select(.value != []) | .key] | join(" ")' "$sources")" "$rebuilt" \
  "the checks rebuilt for one file of every set, against the checks with a set"

# --- coverage -------------------------------------------------------------------

uncovered=$(git -C "$repo" ls-files | jq -R . | jq -rs --slurpfile map "$sources" '
  ($map[0] | [.covers[][], .untested[], .evaluated[]] | unique) as $known
  | map(select(. as $file | $known | index($file) | not)) | join(" ")')
assert_eq "" "$uncovered" "files in no check's set and in no list of nix/check-sources.nix"
