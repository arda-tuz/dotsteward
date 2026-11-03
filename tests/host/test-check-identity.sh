# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The framework checks depend on the files of the framework, never on the
# commit that holds them: for two commits with the same tree (the second an
# empty commit a day later), every checks.x86_64-linux derivation is the
# same, so an amended, rebased or re-made commit rebuilds no check. The
# shipped CLI (packages.x86_64-linux.dotsteward) still reports the revision
# of its own commit, and the same narHash for the same tree, in
# `dotsteward version --json`.
#
# Real Nix evaluates and builds the flake of a git repository that holds the
# tree of the checkout under test (its tracked and untracked files that git
# does not ignore), so this test runs on the host, like every test of
# tests/host, and never in the build sandbox, which has no Nix daemon.

command -v nix >/dev/null 2>&1 || ds_fail "this test needs nix on PATH"
git -C "$DS_REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  ds_fail "this test needs a git checkout of the framework: $DS_REPO_ROOT"

nix_flakes() {
  nix --extra-experimental-features 'nix-command flakes' "$@"
}

# --- two commits of the tree under test -----------------------------------------

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
GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z \
  git -C "$repo" commit -q -m "test: the framework tree"
first=$(git -C "$repo" rev-parse HEAD)
GIT_AUTHOR_DATE=2026-01-02T00:00:00Z GIT_COMMITTER_DATE=2026-01-02T00:00:00Z \
  git -C "$repo" commit -q --allow-empty -m "test: the same tree again"
second=$(git -C "$repo" rev-parse HEAD)
assert_eq "$(git -C "$repo" rev-parse "$first^{tree}")" "$(git -C "$repo" rev-parse "$second^{tree}")" \
  "the two commits hold one tree"

# --- the checks: one derivation per check, whatever the commit ------------------

# checks_of REV FILE: {name: drvPath} of checks.x86_64-linux at commit REV.
checks_of() {
  nix_flakes eval --json "git+file://$repo?rev=$1#checks.x86_64-linux" \
    --apply 'checks: builtins.mapAttrs (name: check: check.drvPath) checks' >"$2" ||
    ds_fail "the checks of commit $1 do not evaluate"
}
checks_of "$first" "$DS_TEST_ROOT/first.json"
checks_of "$second" "$DS_TEST_ROOT/second.json"

expected=$(find "$repo/nix/checks" -maxdepth 1 -type f -name '*.nix' | wc -l)
assert_eq "$((expected))" "$(jq length "$DS_TEST_ROOT/first.json")" "every check evaluated"
differing=$(jq -rn --slurpfile a "$DS_TEST_ROOT/first.json" --slurpfile b "$DS_TEST_ROOT/second.json" \
  '[($a[0] | keys) + ($b[0] | keys) | unique[] | select($a[0][.] != $b[0][.])] | join(" ")')
assert_eq "" "$differing" "checks whose derivation depends on the commit rather than the tree"

# --- the shipped CLI: the revision of its own commit ------------------------------

hashes=()
for rev in "$first" "$second"; do
  cli=$(nix_flakes build --no-link --print-out-paths "git+file://$repo?rev=$rev#dotsteward") ||
    ds_fail "the CLI of commit $rev does not build"
  assert_exit 0 "$cli/bin/dotsteward" version --json
  assert_eq "$rev" "$(jq -r .rev <<<"$DS_STDOUT")" "the revision the packaged CLI reports"
  hashes+=("$(jq -r .narHash <<<"$DS_STDOUT")")
done
[[ ${hashes[0]} == sha256-* ]] || ds_fail "the packaged CLI reports no narHash: [${hashes[0]}]"
assert_eq "${hashes[0]}" "${hashes[1]}" "the narHash of one tree"
