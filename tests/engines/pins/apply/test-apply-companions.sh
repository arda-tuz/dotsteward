# shellcheck shell=bash
# The download pin of a binary and the pins of the companions its component installs next to it
# move as one group: both move together, and when the upstream of one cannot be read the other
# waits too, so no binary is published with a companion of another release.
# shellcheck source=tests/engines/pins/apply/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/apply/helpers.sh"

apply_world
json_edit "$manifest" '
data["components"].append({"name": "example-release", "method": "official-binary", "install": {
  "pin": "agent_tools.example-release", "dest": "~/.local/bin/example-release",
  "companions": [{"pin": "desktop_packages.example-desktop", "file": "example-helper"}]}})
'
git -C "$inst" add -A
git -C "$inst" commit -q -m "a binary with a companion"
digest=$(printf '%064d' 7)
binary=$(row agent_tools.example-release github-release 4.0.0 4.1.0 update '{"tag":"v4.1.0","asset":"example-release-linux-x64.tar.gz","size":4242,"sha256":"'"$digest"'","url":"https://downloads.example.invalid/example-release/v4.1.0/example-release-linux-x64.tar.gz"}')
helper=$(row desktop_packages.example-desktop github-release 1.5.0 1.6.0 update '{"tag":"v1.6.0","assets":{"linux":{"asset":"example-desktop_1.6.0_amd64.deb","size":300,"sha256":"'"$digest"'","url":"https://downloads.example.invalid/example-desktop_1.6.0_amd64.deb"}}}')

# The upstream of the companion gives no answer: the binary waits with it.
rows "$binary" "$(row job-0 error "" "" error '{"error":"gh api failed: error connecting to api.github.com","ids":["desktop_packages.example-desktop"]}')"
before=$(tree_state)
assert_exit 6 apply --latest "$rows" --json
assert_eq '[]' "$(jq -c '[.moved[].id]' <<<"$DS_STDOUT")"
assert_eq '[{"group":"download:agent_tools.example-release","outcome":"skipped"}]' "$(jq -c '[.groups[] | {group, outcome}]' <<<"$DS_STDOUT")"
assert_eq "$before" "$(tree_state)"

# Both have an answer: one group moves both.
rows "$binary" "$helper"
assert_exit 0 apply --latest "$rows" --json
assert_eq '["agent_tools.example-release","desktop_packages.example-desktop"]' "$(jq -c '[.moved[].id]' <<<"$DS_STDOUT")"
assert_eq '["download:agent_tools.example-release"]' "$(jq -c '[.groups[].group]' <<<"$DS_STDOUT")"
