# shellcheck shell=bash
# Flake inputs: flake.nix is rewritten, `nix flake lock` runs, the lock fields
# and the pins that derive from the input follow, and a pin's fixed-output hash
# is computed again with the fake-hash technique even though Nix would accept
# the stale one. Channel inputs move to the head of their branch; a newer series
# is a review item. --skip leaves rows alone, which is what the weekly cadence
# needs.
# shellcheck source=tests/engines/pins/apply/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/apply/helpers.sh"

apply_world
term=$github/example/example-term
nixpkgs=$github/example/nixpkgs
head=$(git -C "$nixpkgs" rev-parse main)

old_hash=$(json_get "$versions" '.nix_packages["example-term"].source_nix_sha256')
rows \
  "$(row flake_inputs.example-term github-release 1.2.0 1.3.0 update '{"tag":"v1.3.0"}')" \
  "$(row flake_inputs.nixpkgs channel-head d93fc7d10ddf "${head:0:12}" update '{"channel":"example-26.05","head":"'"$head"'","newest_series":"example-26.05"}')"

assert_exit 0 apply --latest "$rows" --json
summary=$DS_STDOUT

assert_contains "$(<"$inst/flake.nix")" '"github:example/example-term/v1.3.0"'
assert_contains "$(<"$inst/flake.nix")" "\"github:example/nixpkgs/$head\""
assert_eq '"v1.3.0"' "$(json_get "$inst/flake.lock" '.nodes["example-term"].original.ref')"
commit=$(git -C "$term" rev-parse 'refs/tags/v1.3.0^{commit}')
assert_eq "\"$commit\"" "$(json_get "$inst/flake.lock" '.nodes["example-term"].locked.rev')"

input=$(json_get "$versions" '.flake_inputs["example-term"] | [.reference, .version, .revision, .tag_object]')
assert_eq "[\"github:example/example-term/v1.3.0\",\"1.3.0\",\"$commit\",\"$(git -C "$term" rev-parse refs/tags/v1.3.0)\"]" "$input"
assert_eq "\"$head\"" "$(json_get "$versions" '.flake_inputs.nixpkgs.revision')"

package=$(json_get "$versions" '.nix_packages["example-term"] | [.expected, .resolved, .official_tag, .tag_revision]')
assert_eq "[\"1.3.0\",\"1.3.0\",\"v1.3.0\",\"$commit\"]" "$package"

# The hash that changes: the stale hash is in the store, so only a build with
# the placeholder could notice.
new_hash=$(json_get "$versions" '.nix_packages["example-term"].source_nix_sha256')
assert_eq "\"$(fake_hash "example-term.src:1.3.0")\"" "$new_hash"
[[ $new_hash != "$old_hash" ]] || ds_fail "the source hash did not change"

assert_contains "$(<"$FAKE_NIX_STATE/calls")" "flake lock"
assert_contains "$(<"$FAKE_NIX_STATE/calls")" "dotstewardMirrors"
assert_contains "$(<"$FAKE_NIX_STATE/calls")" "lib.pinnedVersions"
assert_eq '["flake_inputs.example-term","flake_inputs.nixpkgs"]' \
  "$(jq -c '.flake_inputs_moved | sort' <<<"$summary")"
assert_eq false "$(jq -c .framework_moved <<<"$summary")"
assert_exit 0 pins check
assert_eq "" "$(git -C "$inst" status --porcelain -- agent/skills/example-skill)"

# Nothing is committed: the writer leaves that to the caller.
assert_eq 2 "$(git -C "$inst" rev-list --count HEAD)"

# A newer series of a channel is a review item; the input still moves to the
# head of the branch it is on.
apply_world_again() {
  git -C "$inst" reset -q --hard
  git -C "$inst" clean -qfd
  : >"$FAKE_NIX_STATE/calls"
}
apply_world_again
rows "$(row flake_inputs.nixpkgs channel-head d93fc7d10ddf "${head:0:12}" review '{"channel":"example-26.05","head":"'"$head"'","newest_series":"example-26.11"}')"
assert_exit 3 apply --latest "$rows"
assert_eq "series-available flake_inputs.nixpkgs" "$(item_codes)"
assert_eq "\"$head\"" "$(json_get "$versions" '.flake_inputs.nixpkgs.revision')"
assert_exit 0 pins check

# Only the newer series, the branch has not moved: the item and no write.
apply_world_again
pinned=$(json_get "$versions" '.flake_inputs.nixpkgs.revision' | tr -d '"')
rows "$(row flake_inputs.nixpkgs channel-head "${pinned:0:12}" "${pinned:0:12}" review '{"channel":"example-26.05","head":"'"$pinned"'","newest_series":"example-26.11"}')"
before=$(tree_state)
assert_exit 3 apply --latest "$rows"
assert_eq "$before" "$(tree_state)"

# --skip takes globs: a week that is not due for Nix leaves every input alone.
apply_world_again
rows "$(row flake_inputs.example-term github-release 1.2.0 1.3.0 update '{"tag":"v1.3.0"}')"
before=$(tree_state)
assert_exit 0 apply --latest "$rows" --skip 'flake_inputs.*' --json
assert_eq "$before" "$(tree_state)"
assert_eq '["skipped flake_inputs.example-term"]' "$(jq -c '[.lines[] | "\(.status) \(.id)"]' <<<"$DS_STDOUT")"
assert_eq '[]' "$(jq -c .flake_inputs_moved <<<"$DS_STDOUT")"
assert_eq "" "$(<"$FAKE_NIX_STATE/calls")"

# A reference flake.nix does not hold exactly once is refused, nothing moves.
apply_world_again
sed -i 's|^  outputs|  # again "github:example/example-term/v1.2.0"\n  outputs|' "$inst/flake.nix"
git -C "$inst" add -A
git -C "$inst" commit -q -m "two references"
before=$(tree_state)
assert_exit 1 apply --latest "$rows"
assert_contains "$DS_STDERR" "flake.nix holds"
assert_eq "$before" "$(tree_state)"
