# shellcheck shell=bash
# shellcheck disable=SC2153 # DS_REPO_ROOT comes from tests/lib/harness.sh
# The flow of skills/dotsteward-maintain: the frontmatter text,
# the reference set, the start sequence, the single maintain-scope gate after
# staging, the fixed commit, activate, verify and publish order, the version
# and skill steps of the implementation, the settings buffer workflow, and no
# legacy script path or engine command (the CLI commands do that work).

skill_dir=$DS_REPO_ROOT/skills/dotsteward-maintain
skill=$skill_dir/SKILL.md
[[ -f $skill ]] || ds_fail "missing skills/dotsteward-maintain/SKILL.md"

# first_line FILE AFTER TEXT: the first line number greater than AFTER that
# contains TEXT (fixed string), or fails the test.
first_line() {
  local file=$1 after=$2 text=$3 found
  found=$(awk -v after="$after" -v text="$text" 'NR > after && index($0, text) { print NR; exit }' "$file")
  [[ -n $found ]] || ds_fail "${file#"$DS_REPO_ROOT"/}: no [$text] after line $after"
  printf '%s\n' "$found"
}

# in_order FILE TEXT...: every TEXT occurs, each after the previous one.
in_order() {
  local file=$1 line=0 text
  shift
  for text in "$@"; do
    line=$(first_line "$file" "$line" "$text")
  done
}

# fenced FILE: the lines inside fenced blocks.
fenced() {
  awk '/^[ \t]*(```|~~~)/ { open = !open; next } open { print }' "$1"
}

# Frontmatter: the skill description, word for word.
expected_description="Add, remove, replace, reconfigure, migrate or selectively update components (applications, CLIs, agent skills, application settings, portable state) in the user's dotsteward instance repository so they reproduce on a fresh machine, optionally activate them on this machine, write locally changed application settings to the repository, or track and untrack such a setting. Do not use for changes meant only for this machine; use dotsteward-update for full version refreshes and dotsteward-contribute for changes to the framework itself."
description=$(awk 'NR == 1 { next } /^---[ \t]*$/ { exit } /^description:/ { sub(/^description:[ \t]*/, ""); print }' "$skill")
assert_eq "$expected_description" "$description" "frontmatter description"

# References: exactly the spec's four plus the shared classification.
references=$(find "$skill_dir/references" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')
assert_eq "classification.md component-contract.md framework-map.md integration-contract.md local-maintained-files.md " \
  "$references" "reference files"

# Start: context, overlay, classification, then the remote check, the dirty
# tree, the read-only preflight of the current profile, the maintain-scope
# prepare and the settings status, in this order.
in_order "$skill" \
  "dotsteward context --json" \
  "overlay" \
  "references/classification.md" \
  "git remote get-url origin" \
  "git status --porcelain" \
  "dotsteward preflight --read-only --json --profile" \
  "dotsteward update prepare --official-sources-only --scope maintain" \
  "dotsteward settings status"
assert_contains "$(grep -F 'dotsteward preflight --read-only' "$skill")" ".profiles.current" \
  "preflight uses the current profile of the context"

# Plan: version changes follow the update skill's references and pins latest.
assert_contains "$(<"$skill")" "../dotsteward-update/references/" "plan links the update references"
assert_contains "$(fenced "$skill")" "dotsteward pins latest" "plan researches candidates with pins latest"

# Implement: pins then sync; a new instance skill gets its lock digests.
in_order "$skill" "versions.lock.json" "dotsteward sync"
assert_contains "$(fenced "$skill")" "dotsteward pins sync --skill" "new instance skill refreshes its digests"
assert_contains "$(<"$skill")" "--check-only" "installers keep a --check-only validation"
assert_contains "$(<"$skill")" "gate.updatePaths" "the update allowlist comes from gate.updatePaths"

# Validate once: stage, then the one maintain-scope gate, in the background.
in_order "$skill" "git add -A" "dotsteward gate --scope maintain"
[[ $(grep -c 'dotsteward gate' <(fenced "$skill")) == 1 ]] ||
  ds_fail "SKILL.md runs the gate in more than one fenced command"
grep -qi 'background' "$skill" || ds_fail "SKILL.md does not run the gate in the background"
grep -q 'timeout 60' "$skill" || ds_fail "SKILL.md does not bound network commands with timeout 60"

# Commit, activate, verify, publish: fixed order after the gate.
in_order "$skill" \
  "dotsteward gate --scope maintain" \
  "git commit" \
  "dotsteward rebuild --profile" \
  "dotsteward e2e --profile" \
  "dotsteward update publish --scope maintain"
assert_contains "$(fenced "$skill" | grep -F 'dotsteward rebuild')" "--switch" "rebuild switches"
# shellcheck disable=SC2016 # the literal command text
assert_contains "$(fenced "$skill" | grep -F 'dotsteward e2e')" \
  '--expected-remote-base "$(dotsteward update status --json | jq -r .candidate.base_oid)"' \
  "e2e takes the prepared base"

# Settings: the plain-text decision report by default, and the buffer
# workflow of the reference in its order.
settings_ref=$skill_dir/references/local-maintained-files.md
grep -qi 'plain text' "$skill" || ds_fail "SKILL.md does not default to a plain-text decision report"
in_order "$settings_ref" \
  "dotsteward settings status --json" \
  "dotsteward settings resolve" \
  "dotsteward settings flush" \
  "dotsteward gate --scope maintain" \
  "dotsteward update publish --scope maintain" \
  "dotsteward settings reconcile"
for word in track track-file untrack validate; do
  grep -q "dotsteward settings $word" "$settings_ref" ||
    ds_fail "local-maintained-files.md does not describe dotsteward settings $word"
done

# No legacy script path (scripts/<name>.sh or scripts/<name>.py) and no
# direct engine command: `dotsteward settings` runs the engine.
for file in "$skill" "$skill_dir"/references/*.md "$skill_dir/agents/openai.yaml"; do
  if grep -qE -- '(^|[^A-Za-z0-9_.-])scripts/[A-Za-z0-9_.-]+\.(sh|py)\b' "$file"; then
    ds_fail "${file#"$DS_REPO_ROOT"/} names a legacy script path"
  fi
  for stale in 'local-maintained-files status' 'local-maintained-files flush'; do
    if grep -qF -- "$stale" "$file"; then
      ds_fail "${file#"$DS_REPO_ROOT"/} still names [$stale]"
    fi
  done
done
