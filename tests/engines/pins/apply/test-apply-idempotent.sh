# shellcheck shell=bash
# A second run with the same rows writes nothing, not even generated_at, and runs
# no build. A run that failed is finished by the next one. The instance lock holds
# a second writer back.
# shellcheck source=tests/engines/pins/apply/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/apply/helpers.sh"

apply_world
digest=$(printf '%064d' 7)
all_rows() {
  rows \
    "$(row flake_inputs.example-term github-release 1.2.0 1.3.0 update '{"tag":"v1.3.0"}')" \
    "$(row agent_tools.example-release github-release 4.0.0 4.1.0 update '{"tag":"v4.1.0","size":1,"sha256":"'"$digest"'","url":"https://downloads.example.invalid/example-release/v4.1.0/example-release-linux-x64.tar.gz"}')" \
    "$(row npm.example-cli npm 2.0.0 2.1.0 update '{"git_head":"'"$(printf 'c%.0s' {1..40})"'"}')" \
    "$(row agent_tools.example-app npm 3.1.0 3.2.0 update '{"git_head":null}')" \
    "$(row pypi.example-tool pypi 1.0.0 1.1.0 update)" \
    "$(row skills.example-vendored skill-source "${skill_old:0:12}" "${skill_new:0:12}" review '{"head":"'"$skill_new"'","changed_paths":["skills/example-vendored/references/notes.md"]}')" \
    "$(row framework framework v1.2.0 v1.3.0 review '{"tag":"v1.3.0"}')"
}
all_rows

assert_exit 0 apply --latest "$rows" --json
assert_eq 7 "$(jq -c '[.moved[]] | length' <<<"$DS_STDOUT")"
assert_exit 0 pins check
after_first=$(tree_state)
first_generated=$(json_get "$versions" .generated_at)
: >"$FAKE_NIX_STATE/calls"

# The saved rows again, as the producer does on a new tip: nothing to do.
assert_exit 0 apply --latest "$rows" --json
assert_eq '[]' "$(jq -c .moved <<<"$DS_STDOUT")"
assert_eq "$after_first" "$(tree_state)" "the second run changed the instance"
assert_eq "$first_generated" "$(json_get "$versions" .generated_at)"
assert_eq "" "$(grep -E '^(.* )?(flake lock|build) ' "$FAKE_NIX_STATE/calls" || true)" "the second run built"
assert_exit 0 pins check

# A failed run leaves its rows for the next one, which finishes the job.
git -C "$inst" add -A
git -C "$inst" commit -q -m "first move"
git -C "$inst" reset -q --hard HEAD~1
all_rows
printf 'example-term\n' >"$FAKE_NIX_STATE/fail-lock"
assert_exit 1 apply --latest "$rows"
rm -f -- "$FAKE_NIX_STATE/fail-lock"
assert_eq '"1.2.0"' "$(json_get "$versions" '.flake_inputs["example-term"].version')"
assert_exit 0 apply --latest "$rows" --json
assert_eq '["flake_inputs.example-term"]' "$(jq -c '[.moved[].id]' <<<"$DS_STDOUT")"
assert_eq '"1.3.0"' "$(json_get "$versions" '.flake_inputs["example-term"].version')"
assert_exit 0 pins check

# Review items of the last run go away with the row.
rows "$(row agent_tools.example-compat npm 1.0.0 1.0.1 update)"
assert_exit 3 apply --latest "$rows"
[[ -f "$state/review.json" ]] || ds_fail "missing $state/review.json"
rows "$(row agent_tools.example-compat npm 1.0.0 1.0.0 current)"
assert_exit 0 apply --latest "$rows"
[[ ! -e "$state/review.json" ]] || ds_fail "unexpected $state/review.json"

# The instance lock: a second writer is refused while another one holds it, and
# nothing is written.
started=$DS_TEST_ROOT/started
release=$DS_TEST_ROOT/release
internal lock run --holder upgrade --state-root "$state" -- bash "$DS_REPO_ROOT/tests/lib/hold.sh" "$started" "$release" &
holder=$!
until [[ -e $started ]]; do
  ((SECONDS < 60)) || ds_fail "the holder did not start"
  sleep 0.02
done
before=$(tree_state)
rows "$(row agent_tools.example-release github-release 4.1.0 4.2.0 update '{"tag":"v4.1.0","size":1,"sha256":"'"$digest"'","url":"https://downloads.example.invalid/example-release/v4.2.0/example-release-linux-x64.tar.gz"}')"
assert_exit 1 apply --latest "$rows"
assert_contains "$DS_STDERR" "upgrade"
assert_eq "$before" "$(tree_state)"
: >"$release"
wait "$holder"

# Under the lock of its caller the writer runs nested.
assert_exit 0 internal lock run --holder upgrade --state-root "$state" -- \
  "$DS_REPO_ROOT/cli/dotsteward" --instance "$inst" pins apply --latest "$rows" --plan
