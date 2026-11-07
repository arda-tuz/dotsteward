# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# Helpers for the tests of `dotsteward incoming`. Not a test file.
#
# The world of tests/skills-tracking/capture-helpers.sh: a bare remote, and machines
# with their own clone, home and state root. On top of it:
#
#   machine_up NAME       new_machine, then `agents install` once, as a machine that
#                         is set up: what the instance holds is what it knows
#   captured NAME SKILL   the machine writes the own skill SKILL and captures it
#   edited NAME SKILL TEXT
#                         the machine adds TEXT to its copy of SKILL and captures it
#   up_to_date NAME       the checkout of the machine goes to the tip of the remote
#   agents NAME ARG...    `agents ARG... --profile workstation`, any status
#   waiting NAME          the ids `incoming list --json` names, one line, sorted
#   skipped NAME KIND     jq -c over skip.KIND of `skills effective`
#   copy_of NAME SKILL    the copy of SKILL in the canonical root of the machine
#   ask_on_tty NAME ANSWERS ARG...
#                         `dotsteward ARG...` on the machine on a pseudo terminal: each
#                         line of ANSWERS goes in when the output stops at a prompt; the
#                         output on standard output, the status of the command
#   by_hand NAME TEXT     commits what the clone holds with the subject TEXT and no trail
#                         of a machine, and pushes it

# shellcheck source=tests/skills-tracking/capture-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/capture-helpers.sh"

agents() {
  local name=$1 action=$2
  shift 2
  ds "$name" agents "$action" --profile workstation "$@"
}

machine_up() {
  new_machine "$1"
  assert_exit 0 agents "$1" install --skip-validation
}

captured() {
  own_new "$1" "$2"
  settle "$1" "$2"
  assert_exit 0 ds "$1" skills capture --now
}

edited() {
  printf '%s\n' "$3" >>"$(copy_of "$1" "$2")/SKILL.md"
  wrote "$1" "$2"
  settle "$1" "$2"
  assert_exit 0 ds "$1" skills capture --now
}

up_to_date() {
  git -C "$(clone_of "$1")" pull -q --ff-only origin main
}

waiting() {
  assert_exit 0 ds "$1" incoming list --json
  jq -r '[.items[].id] | sort | join(" ")' <<<"$DS_STDOUT"
}

skipped() {
  assert_exit 0 ds "$1" skills effective --json
  jq -c ".skip.$2" <<<"$DS_STDOUT"
}

copy_of() {
  local found
  for found in "$(home_of "$1")/.agents/skills/$2" "$(home_of "$1")/.claude/skills/$2"; do
    if [[ -f $found/SKILL.md ]]; then
      printf '%s\n' "$found"
      return 0
    fi
  done
  printf '%s\n' "$(home_of "$1")/.agents/skills/$2"
}

by_hand() {
  git -C "$(clone_of "$1")" add -A
  git -C "$(clone_of "$1")" commit -q -m "$2"
  git -C "$(clone_of "$1")" push -q origin main
}

# A skill in the lock and the tree of the clone, not captured: what a commit by hand brings.
hand_skill() {
  local clone dir digest skill_digest revision=${3:-$own_skill_revision}
  clone=$(clone_of "$1")
  dir=$clone/agent/skills/$2
  mkdir -p "$dir"
  printf -- '---\nname: %s\ndescription: Synthetic skill.\n---\n\n# %s\n' "$2" "$2" >"$dir/SKILL.md"
  digest=$(local_digest "$dir")
  skill_digest=$(sha256sum "$dir/SKILL.md" | cut -d' ' -f1)
  jq --arg name "$2" --arg digest "$digest" --arg skill "$skill_digest" --arg revision "$revision" \
    '.skills += [{name: $name, directory: $name, revision: $revision, skill_sha256: $skill, directory_sha256: $digest}]' \
    "$clone/agent/skills.lock.json" >"$clone/agent/skills.lock.tmp"
  mv -- "$clone/agent/skills.lock.tmp" "$clone/agent/skills.lock.json"
}
own_skill_revision=same-as-instance-checkout

ask_on_tty() {
  local name=$1 answers=$2
  shift 2
  on "$name" python3 -I "$DS_REPO_ROOT/tests/incoming/tty.py" "$answers" "$DS_REPO_ROOT/cli/dotsteward" "$@"
}
