# shellcheck shell=bash
# shellcheck disable=SC2153 # DS_REPO_ROOT comes from tests/lib/harness.sh
# The flow of skills/dotsteward-maintain: the frontmatter text,
# the reference set, the start sequence that ends in `maintain begin`, one
# `dotsteward apply` for the gate, commit, activate, verify and publish steps
# (after a red E2E too: a new commit through apply, which runs the gate, the
# rebuild, then E2E again), none of those steps by hand, the version and skill
# steps of the implementation, the settings buffer workflow, the report in the
# user's language unless the overlay names one, and no legacy script path or
# engine command (the CLI commands do that work).

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

# Start: context, overlay, classification, then `maintain begin`, which does
# the checkout guards, the preflight, the prepare and the settings status; its
# questions (dirty tree, unpublished commits, local settings, adaptive route)
# go to the user before any write.
in_order "$skill" \
  "dotsteward context --json" \
  "overlay" \
  "references/classification.md" \
  "dotsteward maintain begin --json"
for code in checkout-dirty unpublished-commits settings-local adaptive-route; do
  grep -qF -- "\`$code\`" "$skill" || ds_fail "SKILL.md does not say what to do about $code"
done

# Plan: version changes follow the update skill's references and pins latest.
assert_contains "$(<"$skill")" "../dotsteward-update/references/" "plan links the update references"
assert_contains "$(fenced "$skill")" "dotsteward pins latest" "plan researches candidates with pins latest"

# Implement: pins then sync; a new instance skill gets its lock digests.
in_order "$skill" "versions.lock.json" "dotsteward generate"
assert_contains "$(fenced "$skill")" "dotsteward pins sync --skill" "new instance skill refreshes its digests"
assert_contains "$(<"$skill")" "--check-only" "installers keep a --check-only validation"
assert_contains "$(<"$skill")" "gate.updatePaths" "the update allowlist comes from gate.updatePaths"

# Validate, commit, activate, verify, publish: one apply, in the background,
# with a conventional subject and the activation and publish options. Its
# description names the steps in their fixed order, and no fenced command
# runs one of them by hand.
[[ $(grep -c 'dotsteward apply -m' <(fenced "$skill")) == 1 ]] ||
  ds_fail "SKILL.md does not run exactly one fenced dotsteward apply -m"
assert_contains "$(fenced "$skill" | grep -F 'dotsteward apply -m')" "--activate --publish" \
  "apply takes the activation and publish options"
for step in 'dotsteward gate' 'git commit' 'git add' 'dotsteward rebuild' 'dotsteward e2e' 'dotsteward txn' 'git pull'; do
  if fenced "$skill" | grep -qF -- "$step"; then
    ds_fail "SKILL.md runs [$step] by hand; dotsteward apply does it"
  fi
done
in_order "$skill" \
  "dotsteward apply -m" \
  "git add -A" \
  "dotsteward gate --scope maintain" \
  "trace line" \
  "dotsteward rebuild --profile <profile> --switch" \
  "dotsteward e2e" \
  "dotsteward txn publish --scope maintain"
grep -qi 'background' "$skill" || ds_fail "SKILL.md does not run apply in the background"
grep -q 'timeout 60' "$skill" || ds_fail "SKILL.md does not bound network commands with timeout 60"
grep -qF 'contribute upgrade --carry' "$skill" ||
  ds_fail "SKILL.md does not carry the unpublished commits across a framework fix"

# A red E2E: a new commit, the gate, the rebuild that activates it, then E2E
# again, in this order.
red=$(grep -F 'If E2E fails' "$skill") || ds_fail "SKILL.md does not say what to do when E2E fails"
red_order=$(awk -v text="$red" 'BEGIN {
  n = split("new commit|gate again|rebuild|E2E again", want, "|")
  at = 0
  for (i = 1; i <= n; i++) {
    found = index(substr(text, at + 1), want[i])
    if (!found) { print "missing " want[i]; exit }
    at += found
  }
  print "ok"
}')
assert_eq "ok" "$red_order" "after a red E2E: new commit, gate, rebuild, then E2E again"

# The report: the overlay's language, else the user's.
grep -q "language the overlay asks for, else in the user's language" "$skill" ||
  ds_fail "SKILL.md does not write the report in the user's language when the overlay names none"

# Settings: the plain-text decision report by default, and the buffer
# workflow of the reference in its order.
settings_ref=$skill_dir/references/local-maintained-files.md
grep -qi 'plain text' "$skill" || ds_fail "SKILL.md does not default to a plain-text decision report"
in_order "$settings_ref" \
  "dotsteward settings status --json" \
  "dotsteward settings resolve" \
  "dotsteward settings flush" \
  "dotsteward apply" \
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
