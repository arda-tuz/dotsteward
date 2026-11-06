#!/usr/bin/env bash
# A fake Nix behind the nix stub for the remote contribute tests (installed
# with `ds_stub_override nix`, so the stub records every call first). Not a
# test file.
#
#   flake check ...                  succeeds, or fails when the knob
#                                    flake-check (DS_TEST_ROOT/hub/knobs/
#                                    flake-check) holds "fail"
#   build DIR#dotsteward --out-link LINK ... --override-input dotsteward REF ...
#                                    the CLI of the instance DIR with the
#                                    framework at REF: LINK points to the
#                                    package DS_TEST_ROOT/candidate and its
#                                    path is printed, or it fails when the
#                                    knob candidate-cli holds "fail"; the knob
#                                    holding "empty" makes a package without
#                                    the command
#   flake update dotsteward --flake DIR
#                                    locks the dotsteward input of
#                                    DIR/flake.nix: its url (github:O/R/REF
#                                    or git+ssh://git@github.com/O/R[.git]
#                                    ?ref=refs/tags/REF; like Nix, a git+
#                                    ref without refs/ names a branch, so
#                                    ?ref=REF fails) is resolved
#                                    against the bare repository of O/R in
#                                    DS_TEST_ROOT/hub/repos, and DIR/flake.lock
#                                    gets the node with that ref and the
#                                    tag's commit (the knob lock-rev,
#                                    DS_TEST_ROOT/hub/knobs/lock-rev,
#                                    replaces the commit); a commit instead
#                                    (github:O/R/<40 hex>, or a git+ URL with
#                                    &rev=<40 hex> and ?ref=refs/heads/B) is
#                                    locked as that revision, which must be
#                                    on B (main for github:), with rev in
#                                    original and no ref (github:)
# Anything else fails.
set -euo pipefail

fail() {
  printf 'fake nix: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case $1 in
    --extra-experimental-features | --max-jobs | --cores) shift 2 ;;
    -L | --print-build-logs | --no-warn-dirty) shift ;;
    *) break ;;
  esac
done

hub=$DS_TEST_ROOT/hub

if [[ ${1:-} == build ]]; then
  [[ ${2:-} == *'#dotsteward' && " $* " == *" --override-input dotsteward "* ]] || fail "unsupported: $*"
  package=$DS_TEST_ROOT/candidate
  case $(cat "$hub/knobs/candidate-cli" 2>/dev/null || true) in
    fail) fail "build: the CLI does not build" ;;
    empty)
      package=$DS_TEST_ROOT/candidate-empty
      mkdir -p "$package"
      ;;
  esac
  [[ ${3:-} == --out-link && -n ${4:-} ]] || fail "unsupported: $*"
  ln -sfn "$package" "$4"
  printf '%s\n' "$package"
  exit 0
fi

case "${1:-} ${2:-}" in
  "flake check")
    if [[ -f $hub/knobs/flake-check && $(<"$hub/knobs/flake-check") == fail ]]; then
      fail "flake check: a check failed"
    fi
    exit 0
    ;;
  "flake update") ;;
  *) fail "unsupported: $*" ;;
esac
[[ ${3:-} == dotsteward && ${4:-} == --flake && -n ${5:-} ]] || fail "unsupported: $*"
dir=$5

url=$(awk '
  /dotsteward\.url[[:space:]]*=/ || /dotsteward[[:space:]]*=[[:space:]]*\{.*url[[:space:]]*=/ {
    if (match($0, /"[^"]*"/)) { print substr($0, RSTART + 1, RLENGTH - 2); exit }
  }
  /dotsteward[[:space:]]*=[[:space:]]*\{/ { block = 1; next }
  block && /url[[:space:]]*=/ { if (match($0, /"[^"]*"/)) { print substr($0, RSTART + 1, RLENGTH - 2); exit } }
' "$dir/flake.nix")
pinned=""
if [[ $url =~ ^github:([^/]+)/([^/?]+)/([^?]+)(\?.*)?$ ]]; then
  type=github
  owner=${BASH_REMATCH[1]}
  repo=${BASH_REMATCH[2]}
  ref=${BASH_REMATCH[3]}
  # Nix reads a 40-digit path component as a revision.
  if [[ $ref =~ ^[0-9a-f]{40}$ ]]; then
    pinned=$ref
    ref=refs/heads/main
  fi
elif [[ $url =~ ^git\+ssh://git@github\.com/([^/]+)/([^/?]+)\?(.*&)?ref=([^&]+) ]]; then
  type=git
  owner=${BASH_REMATCH[1]}
  repo=${BASH_REMATCH[2]%.git}
  ref=${BASH_REMATCH[4]}
  if [[ $url =~ [?\&]rev=([0-9a-f]{40})(&|$) ]]; then
    pinned=${BASH_REMATCH[1]}
  fi
else
  fail "cannot lock the dotsteward url: ${url:-none}"
fi
bare=$(awk -F'\t' -v slug="$owner/$repo" 'tolower($1) == tolower(slug) { print $2 }' "$hub/repos")
[[ -n $bare ]] || fail "unknown repository $owner/$repo"
[[ $type != git || $ref == refs/* ]] || fail "couldn't find remote ref refs/heads/$ref in $owner/$repo"
if [[ -n $pinned ]]; then
  [[ $ref == refs/heads/* ]] || fail "a revision is locked from a branch ref, not $ref"
  git -C "$bare" merge-base --is-ancestor "$pinned" "$ref" 2>/dev/null ||
    fail "Cannot find Git revision '$pinned' in ref '$ref' of $owner/$repo"
  rev=$pinned
else
  rev=$(git -C "$bare" rev-parse --verify --quiet "refs/tags/${ref#refs/tags/}^{commit}") || fail "no tag $ref in $owner/$repo"
fi
if [[ -f $hub/knobs/lock-rev ]]; then
  rev=$(<"$hub/knobs/lock-rev")
fi

if [[ $type == github && -n $pinned ]]; then
  node=$(jq -n --arg owner "$owner" --arg repo "$repo" --arg rev "$rev" --arg pinned "$pinned" '{
    locked: {lastModified: 1767225600, narHash: "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=",
             owner: $owner, repo: $repo, rev: $rev, type: "github"},
    original: {owner: $owner, repo: $repo, rev: $pinned, type: "github"}}')
elif [[ $type == github ]]; then
  node=$(jq -n --arg owner "$owner" --arg repo "$repo" --arg ref "$ref" --arg rev "$rev" '{
    locked: {lastModified: 1767225600, narHash: "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=",
             owner: $owner, repo: $repo, rev: $rev, type: "github"},
    original: {owner: $owner, ref: $ref, repo: $repo, type: "github"}}')
else
  base=${url%%\?*}
  base=${base#git+}
  node=$(jq -n --arg url "$base" --arg ref "$ref" --arg rev "$rev" --arg pinned "$pinned" '{
    locked: {lastModified: 1767225600, narHash: "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=",
             ref: $ref, rev: $rev, type: "git", url: $url},
    original: ({ref: $ref, type: "git", url: $url} + (if $pinned == "" then {} else {rev: $pinned} end))}')
fi
jq --argjson node "$node" '.nodes.dotsteward = $node' "$dir/flake.lock" >"$dir/flake.lock.new"
mv "$dir/flake.lock.new" "$dir/flake.lock"
