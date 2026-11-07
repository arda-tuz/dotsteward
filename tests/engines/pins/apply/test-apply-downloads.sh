# shellcheck shell=bash
# Download pins: the fields a download-pin rule names are filled from the row,
# or from a prefetch when the row has no asset. A major version moves unless the
# pin is constrained; a pin the writer cannot fill is a review item, and is never
# half-written.
# shellcheck source=tests/engines/pins/apply/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/apply/helpers.sh"

apply_world
release=$github/example/example-release
digest=$(printf '%064d' 7)

# From the row: url, size, digest; the source revision is the commit of the tag;
# the skills lock mirror follows.
rows "$(row agent_tools.example-release github-release 4.0.0 4.1.0 update '{"tag":"v4.1.0","asset":"example-release-linux-x64.tar.gz","size":4242,"sha256":"'"$digest"'","url":"https://downloads.example.invalid/example-release/v4.1.0/example-release-linux-x64.tar.gz"}')"
assert_exit 0 apply --latest "$rows"
commit=$(git -C "$release" rev-parse 'refs/tags/v4.1.0^{commit}')
assert_eq "[\"4.1.0\",\"https://downloads.example.invalid/example-release/v4.1.0/example-release-linux-x64.tar.gz\",4242,\"$digest\",\"$commit\"]" \
  "$(json_get "$versions" '.agent_tools["example-release"] | [.minimum_version, .url, .size, .sha256, .source_revision]')"
assert_eq "[\"4.1.0\",\"$commit\",4242]" \
  "$(json_get "$skills" '.release_tools["example-release"] | [.version, .source_revision, .size]')"
assert_exit 0 pins check
assert_eq '["download:agent_tools.example-release"]' "$(last_report '[.steps[] | select(.moved) | .name]')"

# An unconstrained major with no asset in the row: the URL follows the version,
# the file is prefetched once for its digest and size.
url=https://downloads.example.invalid/example-release/v5.0.0/example-release-linux-x64.tar.gz
rows "$(row agent_tools.example-release github-release 4.1.0 5.0.0 review '{"tag":"v5.0.0"}')"
assert_exit 0 apply --latest "$rows"
expected=$(printf 'download:%s' "$url" | sha256sum | cut -d' ' -f1)
assert_eq "[\"5.0.0\",\"$url\",\"$expected\",$((${#url} + 9))]" \
  "$(json_get "$versions" '.agent_tools["example-release"] | [.minimum_version, .url, .sha256, .size]')"
assert_contains "$(<"$FAKE_NIX_STATE/calls")" "store prefetch-file --json $url"
assert_exit 0 pins check

# Per-platform assets, without a digest: the digest comes from the prefetch.
desktop=https://downloads.example.invalid/example-desktop_1.6.0_amd64.deb
rows "$(row desktop_packages.example-desktop github-release 1.5.0 1.6.0 update '{"tag":"v1.6.0","assets":{"linux":{"asset":"example-desktop_1.6.0_amd64.deb","size":300,"sha256":null,"url":"'"$desktop"'"}}}')"
assert_exit 0 apply --latest "$rows"
expected=$(printf 'download:%s' "$desktop" | sha256sum | cut -d' ' -f1)
assert_eq "[\"1.6.0\",\"$desktop\",300,\"$expected\"]" \
  "$(json_get "$versions" '.desktop_packages["example-desktop"] | [.minimum_version, .url, .size, .sha256]')"
assert_exit 0 pins check

# The Nix installer: a built-in rule with its own field names.
installer=https://releases.example.invalid/nix/nix-2.31.3/install
rows "$(row nix.installer nix-release 2.31.2 2.31.3 update '{"url":"'"$installer"'","size":4500,"sha256":"'"$digest"'"}')"
assert_exit 0 apply --latest "$rows"
assert_eq "[\"2.31.3\",\"$installer\",4500,\"$digest\"]" \
  "$(json_get "$versions" '.nix | [.version, .installer_url, .installer_size, .installer_sha256]')"
assert_exit 0 pins check

# The release does not have the asset: a review item, the pin stays.
before=$(tree_state)
rows "$(row agent_tools.example-release github-release 5.0.0 5.1.0 update '{"tag":"v5.1.0","asset_missing":"example-release-linux-x64.tar.gz"}')"
assert_exit 3 apply --latest "$rows"
assert_eq "asset-missing agent_tools.example-release" "$(item_codes)"
assert_eq "$before" "$(tree_state)"

# The URL that follows the version does not download: a failed group, restored.
url=https://downloads.example.invalid/example-release/v5.2.0/example-release-linux-x64.tar.gz
printf '%s\n' "$url" >"$FAKE_NIX_STATE/fail-prefetch"
rows "$(row agent_tools.example-release github-release 5.0.0 5.2.0 update '{"tag":"v5.2.0"}')"
_apply_tag() {
  ds_git_commit "$sources/example/example-release" VERSION "$1" "chore: $1"
  git -C "$sources/example/example-release" tag -a "$1" -m "release $1"
  _apply_publish example/example-release
}
_apply_tag v5.2.0
before=$(tree_state)
assert_exit 1 apply --latest "$rows"
assert_contains "$DS_STDERR" "HTTP error 404"
assert_eq "$before" "$(tree_state)"

# A pin with a *_reason is constrained even for a patch; a pin no rule explains
# has no writer. Both stay as they are, and each gets one review item.
rows \
  "$(row agent_tools.example-compat npm 1.0.0 1.0.1 update)" \
  "$(row agent_tools.example-plain npm 1.0.0 2.0.0 review)"
assert_exit 3 apply --latest "$rows"
assert_eq "$before" "$(tree_state)"
assert_eq "pins-constrained agent_tools.example-compat
pins-no-writer agent_tools.example-plain" "$(item_codes | sort)"
assert_contains "$(jq -c '.items[] | select(.code == "pins-constrained")' "$state/review.json")" "another tool needs exactly this version"

# A tag the upstream does not have: the revision cannot be filled, so nothing is.
rows "$(row agent_tools.example-release github-release 5.0.0 5.3.0 update '{"tag":"v5.3.0","size":1,"sha256":"'"$digest"'","url":"https://downloads.example.invalid/example-release/v5.3.0/example-release-linux-x64.tar.gz"}')"
assert_exit 1 apply --latest "$rows"
assert_contains "$DS_STDERR" "v5.3.0"
assert_eq "$before" "$(tree_state)"

# A component table without a `version` constrains nothing, as the schema default says: the pin moves.
# A `version` in it does: the pin stays, with the reason.
cat >>"$inst/workstation.toml" <<'TOML'

[components.example-release]
enable = true
TOML
digest=$(printf '%064d' 7)
later=https://downloads.example.invalid/example-release/v5.1.0/example-release-linux-x64.tar.gz
current=$(json_get "$versions" '.agent_tools["example-release"].minimum_version | ltrimstr("\"") | rtrimstr("\"")')
git -C "$inst" add -A
git -C "$inst" commit -q -m "a component table"
printf '\nversion = "4.*"\n' >>"$inst/workstation.toml"
rows "$(row agent_tools.example-release github-release "$current" 5.1.0 update '{"tag":"v5.1.0","size":1,"sha256":"'"$digest"'","url":"'"$later"'"}')"
assert_exit 0 apply --plan --latest "$rows" --json
assert_contains "$DS_STDOUT" "pins-constrained"
git -C "$inst" checkout -q -- workstation.toml
assert_exit 0 apply --plan --latest "$rows" --json
assert_not_contains "$DS_STDOUT" "pins-constrained"
