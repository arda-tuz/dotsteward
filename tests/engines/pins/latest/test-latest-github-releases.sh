# shellcheck shell=bash
# github-release rows come from the release list of the repository (its
# release JSON), the way GitHub answers it: the newest stable release of the
# tag family by version, whatever GitHub calls latest; drafts and
# prereleases never count, not even through the tags when no release of the
# family is left; the asset, its size and its digest come from the release
# that wins. The fake GitHub answers both the latest release and the list.
# shellcheck source=tests/engines/pins/latest/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/latest/helpers.sh"

latest_world

dir=$(remote_repo example-org/example-cli)
for tag in cli-v1.3.0 cli-v1.5.0 cli-v1.6.0 cli-v1.7.0 desktop-v9.0.0; do
  ds_git_commit "$dir" VERSION "$tag" "chore: $tag"
  git -C "$dir" tag "$tag"
done
publish example-org/example-cli

declare_latest '{"component":"example-cli","id":"agent_tools.example-release","adapter":"github-release","repo":"example-org/example-cli","tag_prefix":"cli-v","at":"agent_tools.example-release","asset":"example-cli-linux-x64.tar.gz"}'

# release TAG DRAFT PRERELEASE [DIGEST]: one release of the list, with the
# asset of the declaration.
release() {
  jq -cn --arg tag "$1" --argjson draft "$2" --argjson prerelease "$3" --arg digest "${4:-}" '{
    tag_name: $tag, draft: $draft, prerelease: $prerelease,
    assets: [{name: "example-cli-linux-x64.tar.gz", size: 4096,
      digest: (if $digest == "" then null else "sha256:" + $digest end),
      browser_download_url: "https://github.com/example-org/example-cli/releases/download/\($tag)/example-cli-linux-x64.tar.gz"}]
  }'
}
# github LATEST RELEASE...: the fake GitHub API of example-cli, newest first,
# with LATEST as the release GitHub calls latest.
github() {
  local latest=$1 list=$DS_TEST_ROOT/releases.json
  shift
  jq -s . <<<"$(printf '%s\n' "$@")" >"$list"
  ds_stub_clear_routes gh
  ds_stub_route gh "api repos/example-org/example-cli/releases/latest" --stdout "$latest"
  ds_stub_route gh "api repos/example-org/example-cli/releases?per_page=100&page=1" --stdout-file "$list"
  ds_stub_route gh "api repos/example-org/example-cli/releases" --stdout-file "$list"
  latest_gh_routes
}

digest5=$(printf '5%.0s' {1..64})
digest4=$(printf '4%.0s' {1..64})
digest2=$(printf '2%.0s' {1..64})

# GitHub calls a release of another tag family latest; the family has a draft,
# a prerelease with a stable-looking tag and a stable release: the stable one
# wins, with its asset and digest from the release JSON.
github "$(release desktop-v9.0.0 false false)" \
  "$(release desktop-v9.0.0 false false)" \
  "$(release cli-v1.7.0 true false)" \
  "$(release cli-v1.6.0 false true)" \
  "$(release cli-v1.5.0 false false "$digest5")" \
  "$(release cli-v1.3.0 false false)"
assert_exit 0 latest --out "$report"
assert_eq "{\"id\":\"agent_tools.example-release\",\"kind\":\"github-release\",\"current\":\"1.3.0\",\"latest\":\"1.5.0\",\"status\":\"update\",\"source\":\"https://github.com/example-org/example-cli/releases\",\"details\":{\"tag\":\"cli-v1.5.0\",\"asset\":\"example-cli-linux-x64.tar.gz\",\"size\":4096,\"sha256\":\"$digest5\",\"url\":\"https://github.com/example-org/example-cli/releases/download/cli-v1.5.0/example-cli-linux-x64.tar.gz\"}}" \
  "$(row agent_tools.example-release)"

# A fix of an older series published after the newer one is what GitHub calls
# latest; the newest version still wins.
rm -rf -- "$sources/example-org/example-cli"
dir2=$(remote_repo example-org/example-cli)
for tag in cli-v1.3.0 cli-v1.4.9 cli-v2.0.0; do
  ds_git_commit "$dir2" VERSION "$tag" "chore: $tag"
  git -C "$dir2" tag "$tag"
done
publish example-org/example-cli
github "$(release cli-v1.4.9 false false "$digest4")" \
  "$(release cli-v1.4.9 false false "$digest4")" \
  "$(release cli-v2.0.0 false false "$digest2")" \
  "$(release cli-v1.3.0 false false)"
assert_exit 0 latest --out "$report"
assert_eq "[\"2.0.0\",\"review\",\"cli-v2.0.0\",\"$digest2\"]" \
  "$(row agent_tools.example-release '[.latest, .status, .details.tag, .details.sha256]')"

# Every release of the family is a draft or a prerelease: their tags are no
# answer either, so the newest stable tag no release flagged answers (without
# asset details).
rm -rf -- "$sources/example-org/example-cli"
dir3=$(remote_repo example-org/example-cli)
for tag in cli-v1.3.0 cli-v1.4.0 cli-v1.8.0 cli-v1.9.0; do
  ds_git_commit "$dir3" VERSION "$tag" "chore: $tag"
  git -C "$dir3" tag "$tag"
done
publish example-org/example-cli
github "$(release desktop-v9.0.0 false false)" \
  "$(release desktop-v9.0.0 false false)" \
  "$(release cli-v1.9.0 true false)" \
  "$(release cli-v1.8.0 false true)"
assert_exit 0 latest --out "$report"
assert_eq '["1.4.0","update",{"tag":"cli-v1.4.0"}]' "$(row agent_tools.example-release '[.latest, .status, .details]')"
