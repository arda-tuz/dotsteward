# shellcheck shell=bash
# The research inside a version constraint takes only a stable release: a tag whose GitHub release
# is a prerelease or a draft is passed over for the one before it.
# shellcheck source=tests/engines/pins/apply/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/apply/helpers.sh"

apply_world
ds_use_stubs gh
ds_stub_route gh "api repos/example/example-release/releases/tags/v4.1.0" \
  --stdout '{"tag_name": "v4.1.0", "prerelease": true, "draft": false, "assets": []}'
# The release list has no release of the family: the research reads the tags.
ds_stub_route gh "api repos/*/releases?per_page=30&page=1" --stdout '[]'
ds_stub_route gh "api repos/*" --exit 1 --stderr "HTTP 404: Not Found"
json_edit "$manifest" '
data["pins"]["latest"] = [
    {"component": "example-release", "id": "agent_tools.example-release", "adapter": "github-release", "at": "agent_tools.example-release", "repo": "example/example-release", "tag_prefix": "v"},
]
'
cat >>"$inst/workstation.toml" <<'TOML'

[components.example-release]
enable = true
version = "4.*"
reason = "the 4.x protocol"
TOML
git -C "$inst" add -A
git -C "$inst" commit -q -m "a constraint and one researched row"

assert_exit 3 apply --json
assert_eq '"4.0.0"' "$(json_get "$versions" '.agent_tools["example-release"].minimum_version')"
assert_eq false "$(jq -c '[.moved[].id] | index("agent_tools.example-release") != null' <<<"$DS_STDOUT")"
assert_contains "$(jq -c '.items[] | select(.code == "pins-constrained")' "$state/review.json")" '"latest":"5.0.0"'
