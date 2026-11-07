# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and up_* variables come from the harness and the helpers
# shellcheck disable=SC2034 # the paths are read by the test files
# Helpers for the tests of `dotsteward maintain begin` and `dotsteward apply` (tests/apply). Not a
# test file.
#
# Sourcing this file sources tests/upgrade/helpers.sh: the synthetic instance up_inst with a bare
# remote behind the fake SSH transport, a machine named example-host with the profile workstation,
# the real dispatcher, gate and txn, and the fakes of rebuild, e2e, pins, static, probes and scan
# that log to UP_LOG and switch on the files of UP_CONTROL. It adds the fakes of tests/apply/fakes
# (install, preflight, settings) and:
#
#   apply ARG...              dotsteward apply through the dispatcher, standard input empty, no
#                             terminal
#   begin ARG...              dotsteward maintain begin, the same way
#   apply_on_terminal ANSWER... -- ARG...
#                             apply on a terminal of its own (see on_terminal)
#   edit TEXT                 appends a line to docs/guide.md, not staged
#   apply_report FILTER       jq FILTER over the newest report of apply is true
#   apply_step NAME           the status of step NAME in the newest report of apply, "none" without
#   machine_trailer COMMIT    the Dotsteward-Machine value in the message of COMMIT
#   add_system_component NAME MODE
#                             a deb component NAME in the mirror for the profile workstation in
#                             MODE (adopt or fresh), not committed

# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

for fake in install preflight settings; do
  cp "$DS_REPO_ROOT/tests/apply/fakes/$fake.sh" "$fw/cli/commands/$fake.sh"
  chmod 0755 "$fw/cli/commands/$fake.sh"
done

apply() {
  "$fw/cli/dotsteward" --instance "$up_inst" apply "$@" </dev/null
}

begin() {
  "$fw/cli/dotsteward" --instance "$up_inst" maintain begin "$@" </dev/null
}

apply_on_terminal() {
  local answers=()
  while (($#)) && [[ $1 != -- ]]; do
    answers+=(--answer "$1")
    shift
  done
  shift
  python3 "$DS_REPO_ROOT/tests/upgrade/terminal.py" ${answers[@]+"${answers[@]}"} -- \
    "$fw/cli/dotsteward" --instance "$up_inst" apply "$@"
}

edit() {
  printf 'line %s\n' "$1" >>"$up_inst/docs/guide.md"
}

newest_apply_report() {
  local file best=-1 number newest=''
  for file in "$DOTSTEWARD_STATE_ROOT"/runs/apply/*.json; do
    [[ -e $file ]] || continue
    number=$(jq -r .sequence "$file")
    if ((number > best)); then
      best=$number
      newest=$file
    fi
  done
  [[ -n $newest ]] || ds_fail "apply wrote no report"
  printf '%s\n' "$newest"
}

apply_report() {
  assert_json "$(newest_apply_report)" "$1"
}

apply_step() {
  jq -r --arg name "$1" '[.steps[] | select(.name == $name) | .status] | last // "none"' "$(newest_apply_report)"
}

machine_trailer() {
  git -C "$up_inst" log -1 --format='%(trailers:key=Dotsteward-Machine,valueonly)' "$1" | sed '/^$/d'
}

add_system_component() {
  local name=$1 mode=$2 file
  file=$up_inst/.dotsteward/manifest.$system.json
  jq --arg name "$name" --arg mode "$mode" '.components += [{
    name: $name, method: "deb", profiles: null, platforms: ["linux"], modes: {workstation: $mode},
    install: {packageNames: [$name]}}]' "$file" >"$file.new"
  mv -- "$file.new" "$file"
}
