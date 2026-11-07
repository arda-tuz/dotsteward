# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and plugin-helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# skills status says what the last capture published and what ignore rules left out of it,
# also while the checkout is behind that capture (review-c1 S4-m2): a file a rule keeps back
# is never silent.
# shellcheck source=tests/skills-tracking/plugin-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/plugin-helpers.sh"

git clone -q "$remote" "$world/edit"
printf '.env\nsecrets/\n' >>"$world/edit/.gitignore"
commit_instance "$world/edit"
git -C "$world/edit" push -q origin HEAD:main

new_machine a
leaky=$(plugin_dir a leaky)
new_plugin a leaky
printf 'TOKEN=example\n' >"$leaky/.env"
mkdir -p "$leaky/secrets"
printf 'example\n' >"$leaky/secrets/key.txt"
tool_wrote a "$leaky/.claude-plugin/plugin.json"
settle_plugin a leaky
ds_code a skills capture --now
if git -C "$remote" cat-file -e refs/heads/main:agent/plugins/leaky/.env 2>/dev/null; then
  ds_fail "an ignored file stays out"
fi
# The checkout is behind the capture.
assert_exit 0 ds a skills status
assert_contains "$DS_STDOUT" "last capture: published leaky"
assert_contains "$DS_STDOUT" "leaky: left out by an ignore rule: .env"
assert_contains "$DS_STDOUT" "leaky: left out by an ignore rule: secrets/key.txt"
assert_exit 0 ds a skills status --json
assert_json - '.last_capture.dropped.leaky == [".env", "secrets/key.txt"]' <<<"$DS_STDOUT"
