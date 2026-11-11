# shellcheck shell=bash
# A new series does not stop the patches of the old one. With `version = "4.*"` and a 5.0.0 upstream,
# the research looks for the newest stable release inside the constraint and the writer moves the
# pin to it; the newest release, outside the constraint, waits as its own `pins-constrained` item,
# with the rule, its reason and that version, for the owner to decide. When nothing newer is inside,
# the outside release still waits. The constraint of a platform a machine runs narrows the search the
# same way. A row of an upstream that gives no list of versions cannot be searched inside the
# constraint: it says so and waits, as before.
# shellcheck source=tests/engines/pins/apply/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/apply/helpers.sh"

apply_world
ds_use_stubs gh
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
reason = "the plugins of this machine speak the 4.x protocol"
TOML
git -C "$inst" add -A
git -C "$inst" commit -q -m "a constraint and one researched row"

pinned() {
  json_get "$versions" '.agent_tools["example-release"].minimum_version' | tr -d '"'
}
waiting() {
  jq -c '[.items[] | select(.code == "pins-constrained" and .id == "agent_tools.example-release")]' "$state/review.json"
}
tag() {
  ds_git_commit "$sources/example/example-release" VERSION "$1" "chore: $1"
  git -C "$sources/example/example-release" tag -a "$1" -m "release $1"
  _apply_publish example/example-release
}

# Upstream has v4.1.0 and v5.0.0: the pin takes 4.1.0, 5.0.0 waits.
assert_exit 3 apply --json
assert_eq 4.1.0 "$(pinned)"
assert_eq true "$(jq -c '[.moved[].id] | index("agent_tools.example-release") != null' <<<"$DS_STDOUT")"
assert_contains "$(json_get "$versions" '.agent_tools["example-release"].url')" "/v4.1.0/"
assert_exit 0 pins check
assert_eq 1 "$(waiting | jq length)"
assert_contains "$(waiting)" '"latest":"5.0.0"'
assert_contains "$(waiting)" "version = '4.*'"
assert_contains "$(waiting)" "the plugins of this machine speak the 4.x protocol"

# Nothing newer inside: no move, and the new series still waits.
before=$(tree_state)
assert_exit 3 apply --json
assert_eq '[]' "$(jq -c .moved <<<"$DS_STDOUT")"
assert_eq "$before" "$(tree_state)"
assert_contains "$(waiting)" '"latest":"5.0.0"'

# A platform constraint narrows the search: a machine on ubuntu-22.04 keeps the pin in 4.1.
tag v4.1.1
tag v4.2.0
mkdir -p "$inst/platforms" "$inst/hosts"
cat >"$inst/platforms/ubuntu-22.04.toml" <<'TOML'
schema_version = 1

[components.example-release]
version = "4.1.*"
reason = "the older release of this platform has only the 4.1 runtime"
TOML
printf 'schema_version = 1\nplatform = "ubuntu-22.04"\n' >"$inst/hosts/example-old.toml"
printf 'schema_version = 1\nplatform = "ubuntu-24.04"\n' >"$inst/hosts/example-new.toml"
git -C "$inst" add -A
git -C "$inst" commit -q -m "a platform constraint and its machine"
assert_exit 3 apply --json
assert_eq 4.1.1 "$(pinned)"
assert_exit 0 pins check
assert_contains "$(waiting)" '"latest":"5.0.0"'
assert_contains "$(waiting)" "platforms/ubuntu-22.04.toml"

# An upstream with no list of versions: its row says only the newest, outside the constraint, so
# nothing inside can be searched, and the row waits.
before=$(tree_state)
rows "$(row agent_tools.example-release official-manifest 4.1.1 5.0.0 review '{}')"
assert_exit 3 apply --latest "$rows"
assert_eq "$before" "$(tree_state)"
assert_contains "$(waiting)" "cannot search inside it"
