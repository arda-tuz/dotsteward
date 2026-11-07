# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# Own skills go out first: the full comparison and the capture come before the fetch, so a push of
# this machine does not look like a remote ahead of it; what waits for a person is said under the
# codes of upgrade. An instance without tracking starts neither. The commands have tests/skills-tracking.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude

cat >"$fw/cli/commands/skills.sh" <<'FAKE'
#!/usr/bin/env bash
# summary: Fake skills of the upgrade tests
printf 'skills %s\n' "$*" >>"$UP_LOG"
if [[ ${1:-} == capture && -e $UP_CONTROL/capture-status ]]; then
  exit "$(<"$UP_CONTROL/capture-status")"
fi
FAKE
chmod 0755 "$fw/cli/commands/skills.sh"

assert_exit 3 upgrade --tracked
assert_no_step '^skills '

set_toml skills tracking true
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "feat: track skills"
git -C "$up_inst" push -q origin HEAD:main

mkdir -p "$DOTSTEWARD_STATE_ROOT/skills"
jq -n '{schema_version: 1, reconciled_at: 0, items: {
  "skill:downloaded": {state: "ask"},
  "skill:both-changed": {state: "conflict"},
  "skill:held-back": {state: "blocked", reason: "privacy"},
  "skill:going-out": {state: "capture"}}}' >"$DOTSTEWARD_STATE_ROOT/skills/pending.json"
clear_log
assert_exit 3 upgrade --tracked
assert_order '^skills reconcile --full' '^skills capture --now' '^pins '
review_json '[.items[] | select(.code == "origin-unknown" and .name == "downloaded")] | length == 1'
review_json '[.items[] | select(.code == "skill-conflict" and .name == "both-changed")] | length == 1'
review_json '[.items[] | select(.code == "capture-blocked" and .name == "held-back" and .reason == "privacy")] | length == 1'
review_json '[.items[] | select(.name == "going-out")] | length == 0'

# A privacy stop of the capture is the status of the run: 4 is the heaviest.
clear_log
printf '4\n' >"$UP_CONTROL/capture-status"
assert_exit 4 upgrade --tracked
assert_order '^skills capture --now' '^rebuild |^e2e |^pins '
rm -f -- "$UP_CONTROL/capture-status"

# No network for the capture: the skill waits, the run says 6 when nothing heavier holds.
printf '6\n' >"$UP_CONTROL/capture-status"
clear_log
assert_exit 3 upgrade --tracked
assert_eq partial "$(step_status skills-capture)"
