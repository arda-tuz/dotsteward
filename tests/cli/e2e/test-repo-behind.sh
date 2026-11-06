# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# Another machine published: `core:repo-remote` lets a checkout behind the remote pass
# with a note, because nothing about this machine is wrong and `git pull --ff-only` moves
# it. A remote commit it does not have yet is fetched without touching a shared ref, so
# concurrent runs and fetches do not fail each other. Ahead and diverged stay failures,
# and a publish that names its base stays strict.
# shellcheck source=tests/cli/e2e/helpers.sh
source "$DS_REPO_ROOT/tests/cli/e2e/helpers.sh"

repo_findings() {
  jq -c '[.findings[] | select(.step | startswith("core:repo")) | [.step, .code]]' <<<"$DS_STDOUT"
}

other=$DS_TEST_ROOT/other-clone
git clone -q "$e2e_bare" "$other"
count=0

# from_elsewhere: another machine publishes one more commit.
from_elsewhere() {
  count=$((count + 1))
  ds_git_commit "$other" "elsewhere-$count.txt" "elsewhere" "docs: elsewhere $count"
  git -C "$other" push -q origin main
}

base=$(git -C "$agents_inst" rev-parse HEAD)
tracking=$(git -C "$agents_inst" rev-parse refs/remotes/origin/main)
assert_exit 0 run_e2e
assert_not_contains "$DS_STDOUT" "behind origin"

# One commit behind, and the commit is not here yet.
from_elsewhere
rm -f -- "$agents_inst/.git/FETCH_HEAD"
remote=$(git -C "$other" rev-parse HEAD)
if git -C "$agents_inst" cat-file -e "$remote^{commit}" 2>/dev/null; then
  ds_fail "the remote commit is here already"
fi
assert_exit 0 run_e2e
assert_contains "$DS_STDOUT" "1 commit behind origin main"
assert_contains "$DS_STDOUT" "git pull --ff-only"
assert_contains "$DS_STDOUT" "e2e checks passed"
assert_eq "$base" "$(git -C "$agents_inst" rev-parse HEAD)" "the checkout moved"
assert_eq "$tracking" "$(git -C "$agents_inst" rev-parse refs/remotes/origin/main)" "a shared ref moved"
assert_eq "" "$(git -C "$agents_inst" status --porcelain)" "the checkout changed"
assert_eq "$tracking" "$(git -C "$agents_inst" for-each-ref --format='%(objectname)' refs/remotes/origin/main)"
assert_eq "" "$(git -C "$agents_inst" for-each-ref --format='%(refname)' refs/dotsteward)" "a run left a ref"
[[ ! -e $agents_inst/.git/FETCH_HEAD ]] || ds_fail "a run left FETCH_HEAD"

# The record holds the run: it passed, with the repository checks.
assert_json "$DOTSTEWARD_STATE_ROOT/update/e2e.json" '.result == "passed" and .repo_checks == true'

# With --json the document stays clean, and the note goes to standard error.
assert_exit 0 run_e2e --json
assert_json - '.result == "passed" and .findings == []' <<<"$DS_STDOUT"
assert_contains "$DS_STDERR" "1 commit behind origin main"

# More commits, and the commit is here already after a fetch.
from_elsewhere
from_elsewhere
git -C "$agents_inst" fetch -q origin
assert_exit 0 run_e2e
assert_contains "$DS_STDOUT" "3 commits behind origin main"

# A publish that names its base stays strict.
assert_exit 1 run_e2e --expected-remote-base "$base" --json
assert_eq '[["core:repo-remote","remote-base-moved"]]' "$(repo_findings)"

# The remote cannot be read.
assert_exit 1 env DS_FAKESSH_FAIL=1 "$agents_fw/cli/dotsteward" --instance "$agents_inst" e2e --profile workstation --json </dev/null
assert_eq '[["core:repo-remote","remote-unreachable"]]' "$(repo_findings)"

# Diverged: this machine has a commit the remote does not.
ds_git_commit "$agents_inst" notes.txt "local work" "docs: local work"
assert_exit 1 run_e2e --json
assert_eq '[["core:repo-remote","remote-mismatch"]]' "$(repo_findings)"
git -C "$agents_inst" reset -q --hard "$base"

# Diverged with a remote commit it has to fetch: still a failure, and no ref is left.
from_elsewhere
ds_git_commit "$agents_inst" notes.txt "local work" "docs: local work"
assert_exit 1 run_e2e --json
assert_eq '[["core:repo-remote","remote-mismatch"]]' "$(repo_findings)"
assert_eq "" "$(git -C "$agents_inst" for-each-ref --format='%(refname)' refs/dotsteward)"
git -C "$agents_inst" reset -q --hard "$base"

# Back on the tip: no note.
git -C "$agents_inst" pull -q --ff-only origin main
assert_exit 0 run_e2e
assert_not_contains "$DS_STDOUT" "behind origin"
git -C "$agents_inst" reset -q --hard "$base"

# Runs and fetches at the same time while the remote moves: a run that has to fetch does
# not fail on a ref another one locks, and does not fail the fetches of the user.
failures=$DS_TEST_ROOT/failures.log
: >"$failures"
for round in 1 2 3; do
  from_elsewhere
  pids=()
  for run in 1 2 3; do
    (
      run_e2e --json >"$DS_TEST_ROOT/run-$round-$run.json" 2>"$DS_TEST_ROOT/run-$round-$run.err" ||
        printf 'e2e %s %s: %s\n' "$round" "$run" "$(<"$DS_TEST_ROOT/run-$round-$run.err")" >>"$failures"
    ) &
    pids+=("$!")
  done
  (
    git -C "$agents_inst" fetch -q origin 2>"$DS_TEST_ROOT/fetch-$round.err" ||
      printf 'fetch %s: %s\n' "$round" "$(<"$DS_TEST_ROOT/fetch-$round.err")" >>"$failures"
  ) &
  pids+=("$!")
  wait "${pids[@]}"
done
assert_eq "" "$(<"$failures")" "a run or a fetch failed"
assert_eq "$base" "$(git -C "$agents_inst" rev-parse HEAD)"
