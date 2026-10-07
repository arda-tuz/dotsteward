# shellcheck shell=bash
# shellcheck disable=SC2153 # DS_REPO_ROOT comes from tests/lib/harness.sh
# The flow of skills/dotsteward-contribute (SPEC 9.4): the frontmatter text,
# the reference set, the step order from the instance facts to the report,
# the reproduction proven failing before the fix, the framework commit
# identity, the VERSION bump of the fix, the stop rules (privacy hard stop,
# back to check, recovery through abort), the build-only trial, resuming a
# run from its state file, the hand-over of the personal part, and no
# command or path of the single-user scripts the CLI replaced.

skill_dir=$DS_REPO_ROOT/skills/dotsteward-contribute
skill=$skill_dir/SKILL.md
[[ -f $skill ]] || ds_fail "missing skills/dotsteward-contribute/SKILL.md"

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

# fenced FILE...: the lines inside fenced blocks.
fenced() {
  awk 'FNR == 1 { open = 0 } /^[ \t]*(```|~~~)/ { open = !open; next } open { print }' "$@"
}

# Frontmatter: the description of SPEC 9.4, word for word.
expected_description="Change the dotsteward framework itself (a skill flow, the CLI, an engine, the gate, a catalog component, the template or framework docs) from the user's machine: reproduce, fix generically, test on this machine, then publish to the user's fork, or in owner mode to the upstream repository with a patch release, and upgrade the user's instance to it. Personal changes belong to dotsteward-maintain."
description=$(awk 'NR == 1 { next } /^---[ \t]*$/ { exit } /^description:/ { sub(/^description:[ \t]*/, ""); print }' "$skill")
# The text holds ": ", which ends a plain YAML scalar, so the skill loaders
# can parse the frontmatter only when the value is double-quoted.
[[ $description == \"*\" ]] || ds_fail "the frontmatter description is not a double-quoted YAML string"
description=${description#\"}
description=${description%\"}
assert_eq "$expected_description" "$description" "frontmatter description"

# References: the shared classification plus the fix, publish and run-state
# guides.
references=$(find "$skill_dir/references" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')
assert_eq "classification.md framework-change.md publish-and-release.md run-state.md " \
  "$references" "reference files"

# The flow: instance facts, overlay, classification, then the steps of SPEC
# 9.4 in their order, the reproduction committed before the fix.
in_order "$skill" \
  "dotsteward context --json" \
  "overlay" \
  "references/classification.md" \
  "dotsteward contribute mode --json" \
  "dotsteward contribute setup" \
  "dotsteward contribute start --slug" \
  "dotsteward contribute check --expect-fail" \
  "TZ=UTC git commit" \
  "VERSION" \
  "TZ=UTC git commit" \
  "dotsteward contribute check" \
  "dotsteward contribute trial" \
  "dotsteward contribute publish" \
  "dotsteward contribute release" \
  "dotsteward contribute upgrade --tag" \
  "dotsteward contribute report" \
  "dotsteward-maintain"
for step in mode setup start check trial publish release upgrade report; do
  assert_contains "$(fenced "$skill")" "dotsteward contribute $step" "SKILL.md runs contribute $step in a fenced block"
done

# Mode: the fallback to fork mode is reported, never an error; a fork is
# created only after the user agrees.
grep -qi 'fallback' "$skill" || ds_fail "SKILL.md does not describe the fork-mode fallback"
assert_contains "$(fenced "$skill")" "dotsteward contribute setup --create-fork" "setup can create the fork"
grep -qi 'agree' "$skill" || ds_fail "SKILL.md does not ask the user before creating a fork"
# shellcheck disable=SC2016 # literal jq text
assert_contains "$(<"$skill")" '.clone' "the clone path comes from the mode document"

# Reproduction and fix: the test path is relative to the clone; the fix is
# generic and never copies instance files.
grep -qi 'relative to the clone' "$skill" || ds_fail "SKILL.md does not say the test path is relative to the clone"
grep -qi 'never copy' "$skill" || ds_fail "SKILL.md does not forbid copying instance files"
grep -q 'references/framework-change.md' "$skill" || ds_fail "SKILL.md does not link references/framework-change.md"

# Framework commits: UTC dates, the noreply identity of setup, no
# attribution trailers; the reference spells out the identity rules.
change_ref=$skill_dir/references/framework-change.md
grep -q 'TZ=UTC git commit' "$change_ref" || ds_fail "framework-change.md does not commit with TZ=UTC"
grep -qi 'noreply' "$change_ref" || ds_fail "framework-change.md does not name the noreply identity"
grep -qi 'trailer' "$change_ref" || ds_fail "framework-change.md does not rule out attribution trailers"

# VERSION: the fix sets it to the next patch release, found from the tags,
# and moves every file that carries the old version.
grep -q 'ls-remote --tags' "$change_ref" || ds_fail "framework-change.md does not find the next release from the tags"
grep -q 'git grep' "$change_ref" || ds_fail "framework-change.md does not find the files that carry the old version"
grep -q 'v0.0.1' "$change_ref" || ds_fail "framework-change.md does not name the first release v0.0.1"

# The framework gate is long: run it in the background and wait once.
grep -qi 'background' "$skill" || ds_fail "SKILL.md does not run the framework gate in the background"

# Stop rules: privacy findings (exit 4) are hard stops, exit 5 sends the run
# back to check, and a red step after a trial switch is recovered; abort ends
# a run with the same recovery.
publish_ref=$skill_dir/references/publish-and-release.md
state_ref=$skill_dir/references/run-state.md
grep -qi 'exit 4' "$skill" || ds_fail "SKILL.md does not stop on exit 4"
grep -qi 'hard stop' "$skill" || ds_fail "SKILL.md does not call privacy findings a hard stop"
grep -qi 'exit 5' "$skill" || ds_fail "SKILL.md does not go back to check on exit 5"
assert_contains "$(fenced "$skill" "$state_ref")" "dotsteward contribute abort" "abort is a fenced command"
grep -qi 'recovery' "$state_ref" || ds_fail "run-state.md does not describe the recovery after a trial switch"
grep -q 'trial_switched' "$state_ref" || ds_fail "run-state.md does not name trial_switched"

# Build-only: for instances that must not activate; publish then needs the
# clean-install workflow green.
assert_contains "$(fenced "$skill" "$publish_ref")" "dotsteward contribute trial --build-only" "trial has a build-only form"
grep -q 'clean-install.yml' "$skill" "$publish_ref" ||
  ds_fail "the skill does not say that a build-only trial needs clean-install.yml"
grep -qi 'fast-forwards the upstream' "$publish_ref" ||
  ds_fail "publish-and-release.md does not describe the owner merge as a fast-forward of the upstream main"
! grep -qi 'squash-merge\|--squash' "$publish_ref" || ds_fail "publish-and-release.md still describes a squash merge"
grep -qi 'tree' "$publish_ref" || ds_fail "publish-and-release.md does not describe the tree check"
grep -q 'pr-to-upstream' "$publish_ref" || ds_fail "publish-and-release.md does not describe the fork's upstream pull request"

# Resume: the state file per run, read with status.
assert_contains "$(fenced "$skill" "$state_ref")" "dotsteward contribute status --json" "status reads the run state"
for field in id slug mode clone branch base_sha test_sha tested_tree trial_switched pr merged_sha tag instance_commit step; do
  grep -q "\`$field\`" "$state_ref" || ds_fail "run-state.md does not describe the state field $field"
done
grep -q 'contribute/<id>.json' "$state_ref" || ds_fail "run-state.md does not name the state file"

# Report: the language comes from the overlay.
grep -qi 'language the overlay' "$skill" || ds_fail "SKILL.md does not take the report language from the overlay"

# No command or path of the single-user scripts the CLI replaced, and no
# fenced command of the instance flow that the contribute steps run
# themselves.
for file in "$skill" "$skill_dir"/references/*.md "$skill_dir/agents/openai.yaml"; do
  # shellcheck disable=SC2088 # literal text, not a path
  for stale in '~/.dotfiles' '.local/state/dotfiles' 'update.sh --' 'scripts/pins.py' \
    'scripts/validate.sh' 'scripts/preflight.sh'; do
    if grep -qF -- "$stale" "$file"; then
      ds_fail "${file#"$DS_REPO_ROOT"/} still names [$stale]"
    fi
  done
done
assert_not_contains "$(fenced "$skill" "$skill_dir"/references/*.md)" "--framework-override" \
  "the trial passes the framework override itself; no fenced command passes it by hand"
