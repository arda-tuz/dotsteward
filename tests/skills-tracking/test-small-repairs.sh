# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# The small things that go wrong around a capture: words of a push that mean the network, a
# record that many processes write, a broken deadline, a FETCH_HEAD nobody asked for, a file
# from the future, a link to a directory nobody may read, the ignore rules of a nested
# clone, and a link into the checkout.
# shellcheck source=tests/skills-tracking/capture-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/capture-helpers.sh"

wrap_git
new_machine a
root=$(home_of a)/.claude/skills

# --- a push that fails with the words of a network problem: it waits, nothing is blocked ---

for said in 'error: RPC failed; HTTP 502 curl 22 The requested URL returned error: 502' \
  'fatal: the remote end hung up unexpectedly'; do
  own_new a flaky
  settle a flaky
  export GIT_WRAP_PUSH_SAYS=$said
  EXPECT_STATUS=6 ds_code a skills capture --now
  unset GIT_WRAP_PUSH_SAYS
  assert_eq capture "$(item a flaky .state)"
  assert_eq offline "$(item a flaky .reason)"
done
ds_code a skills capture --now
assert_eq flaky "$(remote_entry flaky | jq -r .name)"

# --- the fetch of a capture leaves no FETCH_HEAD for a `git pull` to trip over --------------

[[ ! -e $(clone_of a)/.git/FETCH_HEAD ]] || ds_fail "a capture wrote FETCH_HEAD"

# --- base.json keeps what parallel writers record -------------------------------------------

records=()
for number in $(seq 1 16); do
  on a env PYTHONPATH="$DS_REPO_ROOT/cli/python" python3 -m dotsteward_cli.skills.threeway record \
    --instance "$(clone_of a)" --state-root "$(state_of a)" --name "parallel-$number" --found /nowhere \
    --digest "digest-$number" &
  records+=("$!")
done
for pid in "${records[@]}"; do
  wait "$pid"
done
assert_eq 16 "$(jq '[keys[] | select(startswith("skill:parallel-"))] | length' "$(state_of a)/skills/base.json")"

# --- a deadline that is no time ends the sleeper; it neither spins nor stays ------------------

for broken in nan inf -inf; do
  printf '%s\n' "$broken" >"$(state_of a)/skills/deadline"
  runs=$(grep -c ' run$' "$(state_of a)/skills/capture.log")
  assert_exit 0 on a timeout 20 "$DS_REPO_ROOT/cli/dotsteward" skills capture --wait </dev/null
  assert_eq "$runs" "$(grep -c ' run$' "$(state_of a)/skills/capture.log")"
done
rm -f "$(state_of a)/skills/deadline"

# --- a file from the future does not keep a skill back ----------------------------------------

own_new a dated
settle a dated
touch -d '+1 day' "$root/dated/references/guide.md"
ds_code a skills capture --now
assert_eq dated "$(remote_entry dated | jq -r .name)"

# --- a link inside the skill to a directory nobody may read: that skill only, and it says so ---

own_new a hidden
mkdir -p "$root/hidden/closed"
printf 'x\n' >"$root/hidden/closed/file"
ln -s closed "$root/hidden/open"
settle a hidden
ds_code a skills capture --now
chmod 000 "$root/hidden/closed"
ds_defer chmod 755 "$root/hidden/closed"
new_skill a beside
assert_exit 0 ds a skills reconcile --full
assert_eq ask "$(item a beside .state)"
assert_eq capture "$(item a hidden .state)"
EXPECT_STATUS=1 ds_code a skills capture --now --name hidden
assert_eq blocked "$(item a hidden .state)"
assert_eq unsafe-link "$(item a hidden .reason)"
chmod 755 "$root/hidden/closed"
rm -rf "${root:?}/hidden" "${root:?}/beside"
assert_exit 0 ds a skills reconcile --full

# --- a nested clone keeps its own ignore rules ------------------------------------------------

own_new a vendoring
mkdir -p "$root/vendoring/vendor/lib/secret-cache"
git -C "$root/vendoring/vendor/lib" init -q
printf 'secret-cache/\n' >"$root/vendoring/vendor/lib/.gitignore"
printf 'cached\n' >"$root/vendoring/vendor/lib/secret-cache/data"
printf 'code\n' >"$root/vendoring/vendor/lib/code.txt"
wrote a vendoring
settle a vendoring
ds_code a skills capture --now
assert_eq code "$(remote_file agent/skills/vendoring/vendor/lib/code.txt)"
if git -C "$remote" cat-file -e refs/heads/main:agent/skills/vendoring/vendor/lib/secret-cache/data 2>/dev/null; then
  ds_fail "an ignored file of a nested clone left the machine"
fi

# --- a link into the checkout is the checkout, not a new skill --------------------------------

mkdir -p "$(clone_of a)/tools/linked"
printf -- '---\nname: linked\n---\n' >"$(clone_of a)/tools/linked/SKILL.md"
ln -s "$(clone_of a)/tools/linked" "$root/linked"
assert_exit 0 ds a skills reconcile
assert_eq "{}" "$(item a linked .)"
rm -rf "${root:?}/linked" "$(clone_of a)/tools/linked"
