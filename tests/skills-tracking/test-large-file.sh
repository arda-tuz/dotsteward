# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# A very large file in an own skill must not cost every Stop and SessionStart its time limit.
# Its size says enough: the skill is kept back as too-large without reading it, the look
# moves on, and the next hook has nothing to do. A file an ignore rule leaves out is not
# looked at at all.
# shellcheck source=tests/skills-tracking/helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/helpers.sh"

own_skill big
install_hooks claude
agent_event claude Stop stop
copy=$HOME/.agents/skills/big

# stop_in_time: Stop within the time limit of the configuration; 40 GiB take longer to read.
stop_in_time() {
  payload claude stop >"$DS_TEST_ROOT/stop.json"
  timeout 10 sh -c "$(hook_text claude Stop)" <"$DS_TEST_ROOT/stop.json"
}

truncate -s 40G "$copy/model.bin"
assert_exit 0 stop_in_time
assert_eq blocked "$(pending_state big)"
assert_json "$ss/pending.json" '.items["skill:big"].reason == "too-large"'
sleep 2.2
assert_exit 0 stop_in_time
looked=$(jq -r .reconciled_at "$ss/pending.json")
assert_exit 0 stop_in_time
assert_eq "$looked" "$(jq -r .reconciled_at "$ss/pending.json")" "the next look has nothing to do"
# A capture does not read it either.
assert_exit 0 timeout 10 "$agents_fw/cli/dotsteward" --instance "$agents_inst" skills capture --now </dev/null
assert_eq blocked "$(pending_state big)"

# The file goes: back in sync, nothing waits.
rm -f "$copy/model.bin"
assert_exit 0 stop_in_time
assert_eq none "$(pending_state big)"

# An ignored file of that size is none of this.
lock_add quiet --revision "$own_revision"
printf 'model.bin\n' >"$(vendored quiet)/.gitignore"
lock_edit '(.skills[] | select(.name == "quiet")) |= (.directory_sha256 = $dir)' \
  --arg dir "$(bash -c 'source "$1/cli/lib/lib.sh"; directory_sha256 "$2"' _ "$DS_REPO_ROOT" "$(vendored quiet)")"
cp -a "$(vendored quiet)" "$HOME/.agents/skills/quiet"
assert_exit 0 run_agents install
agent_event claude Stop stop
truncate -s 40G "$HOME/.agents/skills/quiet/model.bin"
assert_exit 0 stop_in_time
assert_eq none "$(pending_state quiet)"
