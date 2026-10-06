#!/usr/bin/env bash
# A fake Nix behind the nix stub for the remote contribute tests (installed
# with `ds_stub_override nix`, so the stub records every call first). Not a
# test file.
#
#   flake check ...                  succeeds
#   flake update dotsteward --flake DIR
#                                    locks the dotsteward input of
#                                    DIR/flake.nix: its url (github:O/R/REF
#                                    or git+ssh://git@github.com/O/R[.git]
#                                    ?ref=[refs/tags/]REF) is resolved
#                                    against the bare repository of O/R in
#                                    DS_TEST_ROOT/hub/repos, and DIR/flake.lock
#                                    gets the node with that ref and the
#                                    tag's commit (the knob lock-rev,
#                                    DS_TEST_ROOT/hub/knobs/lock-rev,
#                                    replaces the commit)
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

case "${1:-} ${2:-}" in
  "flake check") exit 0 ;;
  "flake update") ;;
  *) fail "unsupported: $*" ;;
esac
[[ ${3:-} == dotsteward && ${4:-} == --flake && -n ${5:-} ]] || fail "unsupported: $*"
dir=$5
hub=$DS_TEST_ROOT/hub

url=$(awk '
  /dotsteward\.url[[:space:]]*=/ || /dotsteward[[:space:]]*=[[:space:]]*\{.*url[[:space:]]*=/ {
    if (match($0, /"[^"]*"/)) { print substr($0, RSTART + 1, RLENGTH - 2); exit }
  }
  /dotsteward[[:space:]]*=[[:space:]]*\{/ { block = 1; next }
  block && /url[[:space:]]*=/ { if (match($0, /"[^"]*"/)) { print substr($0, RSTART + 1, RLENGTH - 2); exit } }
' "$dir/flake.nix")
if [[ $url =~ ^github:([^/]+)/([^/?]+)/([^?]+)(\?.*)?$ ]]; then
  type=github
  owner=${BASH_REMATCH[1]}
  repo=${BASH_REMATCH[2]}
  ref=${BASH_REMATCH[3]}
elif [[ $url =~ ^git\+ssh://git@github\.com/([^/]+)/([^/?]+)\?(.*&)?ref=([^&]+) ]]; then
  type=git
  owner=${BASH_REMATCH[1]}
  repo=${BASH_REMATCH[2]%.git}
  ref=${BASH_REMATCH[4]}
else
  fail "cannot lock the dotsteward url: ${url:-none}"
fi
bare=$(awk -F'\t' -v slug="$owner/$repo" 'tolower($1) == tolower(slug) { print $2 }' "$hub/repos")
[[ -n $bare ]] || fail "unknown repository $owner/$repo"
rev=$(git -C "$bare" rev-parse --verify --quiet "refs/tags/${ref#refs/tags/}^{commit}") || fail "no tag $ref in $owner/$repo"
if [[ -f $hub/knobs/lock-rev ]]; then
  rev=$(<"$hub/knobs/lock-rev")
fi

if [[ $type == github ]]; then
  node=$(jq -n --arg owner "$owner" --arg repo "$repo" --arg ref "$ref" --arg rev "$rev" '{
    locked: {lastModified: 1767225600, narHash: "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=",
             owner: $owner, repo: $repo, rev: $rev, type: "github"},
    original: {owner: $owner, ref: $ref, repo: $repo, type: "github"}}')
else
  base=${url%%\?*}
  base=${base#git+}
  node=$(jq -n --arg url "$base" --arg ref "$ref" --arg rev "$rev" '{
    locked: {lastModified: 1767225600, narHash: "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=",
             ref: $ref, rev: $rev, type: "git", url: $url},
    original: {ref: $ref, type: "git", url: $url}}')
fi
jq --argjson node "$node" '.nodes.dotsteward = $node' "$dir/flake.lock" >"$dir/flake.lock.new"
mv "$dir/flake.lock.new" "$dir/flake.lock"
