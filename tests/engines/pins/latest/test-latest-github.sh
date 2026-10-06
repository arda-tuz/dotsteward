# shellcheck shell=bash
# github-release rows: the git ls-remote fallback when gh fails or answers
# another tag family, tag prefixes, stable tag selection, asset templates
# ({version}, {tag}) and missing assets, the status model (0.x minor and
# major bumps are reviews, holdbacks are held), and the error row of a
# flake input whose reference is not on GitHub.
# shellcheck source=tests/engines/pins/latest/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/latest/helpers.sh"

latest_world

dir=$(remote_repo example-org/example-cli)
for tag in cli-v1.3.0 cli-v1.5.0 cli-v2.0.0-rc.1 desktop-v9.0.0 v8.0.0; do
  ds_git_commit "$dir" VERSION "$tag" "chore: $tag"
  git -C "$dir" tag "$tag"
done
publish example-org/example-cli

release_declaration='{"component":"example-cli","id":"agent_tools.example-release","adapter":"github-release","repo":"example-org/example-cli","tag_prefix":"cli-v","at":"agent_tools.example-release","asset":"example-cli-linux-x64.tar.gz"}'
declare_latest "$release_declaration"

# The latest release belongs to another tag family: the prefixed stable
# tags answer instead (no release, so no asset details).
ds_stub_clear_routes gh
ds_stub_route gh "api repos/example-org/example-cli/releases/latest" --stdout '{"tag_name": "desktop-v3.0.0"}'
latest_gh_routes
assert_exit 0 latest --out "$report"
assert_eq '{"id":"agent_tools.example-release","kind":"github-release","current":"1.3.0","latest":"1.5.0","status":"update","source":"https://github.com/example-org/example-cli/releases","details":{"tag":"cli-v1.5.0"}}' \
  "$(row agent_tools.example-release)"

# gh fails: same answer from the tags.
ds_stub_clear_routes gh
ds_stub_route gh "api repos/example-org/example-cli/releases/latest" --exit 1 --stderr "HTTP 404: Not Found"
latest_gh_routes
: >"$DS_CALL_LOG"
assert_exit 0 latest --out "$report"
assert_eq '["1.5.0","update",{"tag":"cli-v1.5.0"}]' "$(row agent_tools.example-release '[.latest, .status, .details]')"
assert_call_count 1 gh "api repos/example-org/example-cli/releases/latest"

# gh answers something that is not a release: same answer.
ds_stub_clear_routes gh
ds_stub_route gh "api repos/example-org/example-cli/releases/latest" --stdout '<html>maintenance</html>'
latest_gh_routes
assert_exit 0 latest --out "$report"
assert_eq '["1.5.0","update"]' "$(row agent_tools.example-release '[.latest, .status]')"

# A new major version is a review; an older or equal one is current.
ds_git_commit "$dir" VERSION 2.0.0 "chore: 2.0.0"
git -C "$dir" tag cli-v2.0.0
publish example-org/example-cli
assert_exit 0 latest --out "$report"
assert_eq '["2.0.0","review"]' "$(row agent_tools.example-release '[.latest, .status]')"
json_edit "$versions" 'data["agent_tools"]["example-release"]["minimum_version"] = "2.0.0"'
assert_exit 0 latest --out "$report"
assert_eq '["2.0.0","current"]' "$(row agent_tools.example-release '[.latest, .status]')"
json_edit "$versions" 'data["agent_tools"]["example-release"]["minimum_version"] = "2.1.0"'
assert_exit 0 latest --out "$report"
assert_eq '["2.1.0","2.0.0","current"]' "$(row agent_tools.example-release '[.current, .latest, .status]')"

# A holdback keeps a newer version from becoming an update.
json_edit "$versions" 'pin = data["agent_tools"]["example-release"]; pin["minimum_version"] = "1.3.0"; pin["holdback_reason"] = "2.x changes the archive layout"'
assert_exit 0 latest --out "$report"
assert_eq '["1.3.0","2.0.0","held","2.x changes the archive layout"]' \
  "$(row agent_tools.example-release '[.current, .latest, .status, .details.note]')"
assert_contains "$DS_STDOUT" "2.x changes the archive layout"

# Asset templates: a missing asset is reported, {tag} is the release tag.
ds_stub_clear_routes gh
latest_gh_routes
declare_latest \
  '{"component":"example-term","id":"flake_inputs.example-term","adapter":"github-release","repo":"example-org/example-term","asset":"example-term_{version}_arm64.deb"}' \
  '{"component":"example-term","id":"agent_tools.example-term-archive","adapter":"github-release","repo":"example-org/example-term","at":"flake_inputs.example-term","asset":"example-term-{tag}.tar.gz"}'
assert_exit 0 latest --out "$report"
assert_eq '["0.9.0","review",{"tag":"v0.9.0","asset_missing":"example-term_0.9.0_arm64.deb"}]' \
  "$(row flake_inputs.example-term '[.latest, .status, .details]')"
assert_eq '{"tag":"v0.9.0","asset_missing":"example-term-v0.9.0.tar.gz"}' "$(row agent_tools.example-term-archive .details)"

# 0.x: a minor bump is a review, a patch bump an update.
json_edit "$versions" 'data["flake_inputs"]["example-term"]["version"] = "0.9.0"'
assert_exit 0 latest --out "$report"
assert_eq '"current"' "$(row flake_inputs.example-term .status)"
json_edit "$versions" 'data["flake_inputs"]["example-term"]["version"] = "0.8.9"'
assert_exit 0 latest --out "$report"
assert_eq '"review"' "$(row flake_inputs.example-term .status)"
ds_stub_clear_routes gh
ds_stub_route gh "api repos/example-org/example-term/releases/latest" --stdout '{"tag_name": "v0.8.10", "assets": []}'
latest_gh_routes
assert_exit 0 latest --out "$report"
assert_eq '["0.8.10","update"]' "$(row flake_inputs.example-term '[.latest, .status]')"

# A flake input with a version whose reference is not on GitHub: an error
# row with its id, the other rows still reported, exit 1.
json_edit "$versions" 'data["flake_inputs"]["example-git"] = {"reference": "git+https://example.invalid/example-git.git?ref=v1.0.0", "revision": "18ac3e7343f016890c510e93f935261169d9e3f5", "version": "1.0.0"}'
assert_exit 1 latest --out "$report"
assert_not_contains "$DS_STDERR" "Traceback"
assert_json "$report" '[.items[] | select(.id == "flake_inputs.example-git")] | length == 1'
assert_eq '["github-release","1.0.0",null,"error"]' "$(row flake_inputs.example-git '[.kind, .current, .latest, .status]')"
assert_contains "$(row flake_inputs.example-git .details.error)" "not a GitHub reference"
assert_contains "$DS_STDOUT" $'\nerror    flake_inputs.example-git'
assert_eq '"update"' "$(row flake_inputs.example-term .status)"
