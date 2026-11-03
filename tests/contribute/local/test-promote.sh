# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# `dotsteward contribute start --slug SLUG --promote NAME`: a run that moves
# the private (instance) component NAME into the framework catalog, with the
# user's explicit approval. NAME is a component name (no empty or wildcard
# value) of one of the instance's own components, never a catalog one. The
# run records it as promote (status shows it); its check leaves exactly that
# one term out of the instance-leak scan and says so, while every other
# term, the component's settings targets included, still stops it. Runs
# without --promote and the privacy configuration are unaffected. The same
# slug again with --promote sets it on the unfinished run; another name is
# refused. The report of the run names the promoted component (promote in
# --json, null without one).
# shellcheck source=tests/contribute/local/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/local/helpers.sh"

setup_owner
write_mirror

field() {
  state_json | jq -r "$1"
}

# The nix stub records the terms file of the check, then passes.
cat <<'EOF' | ds_stub_override nix
#!/usr/bin/env bash
set -euo pipefail
for file in "$TMPDIR"/dotsteward-contribute.*/terms; do
  [[ -f $file ]] || continue
  cp "$file" "$DS_TEST_ROOT/terms.copy"
done
EOF

# --- refusals -------------------------------------------------------------------

assert_exit 1 run_contribute start --slug promote-term --promote
assert_contains "$DS_STDERR" "[dotsteward] ERROR: --promote requires a value"
assert_exit 1 run_contribute start --slug promote-term --promote ''
assert_contains "$DS_STDERR" "[dotsteward] ERROR: --promote requires a value"
for name in '*' 'example-*' 'example-term?' '[ab]' 'Example-Term' 'example_term' 'example term' \
  'a/b' '../example-term' '-x' '1example'; do
  assert_exit 1 run_contribute start --slug promote-term --promote "$name"
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: invalid component name for --promote: $name (lowercase letters, digits and dashes, starting with a letter)"
done
assert_exit 1 run_contribute start --slug promote-term --promote example-other
assert_contains "$DS_STDERR" "[dotsteward] ERROR: --promote example-other: the instance has no component of that name; promote moves one of its private components (source = \"instance\") into the framework catalog"
assert_exit 1 run_contribute start --slug promote-term --promote herdr
assert_contains "$DS_STDERR" "[dotsteward] ERROR: --promote herdr: herdr is a catalog component already, not a private one"
[[ ! -e $ct_runs ]] || ds_fail "a refused start wrote run state"
assert_eq main "$(git -C "$ct_clone" symbolic-ref --short HEAD)" "branch after the refusals"

# --- a run that promotes example-term ------------------------------------------

assert_exit 0 run_contribute start --slug promote-term --promote example-term
assert_contains "$DS_STDOUT" "[dotsteward] promote: example-term; the instance-leak scan of this run exempts exactly this name, every other instance term still stops it"
id=$(current_id)
assert_eq example-term "$(field .promote)" "promote of the run"
base=$(git -C "$ct_clone" rev-parse HEAD)
assert_exit 0 run_contribute status
assert_contains "$DS_STDOUT" "  promote: example-term"

# The new catalog component names itself everywhere: the check passes, says
# that the name is exempt, and the terms lack exactly that name.
clone_commit modules/components/example-term/README.md '# example-term' \
  'feat(components): the example-term catalog component'
assert_exit 0 run_contribute check
assert_contains "$DS_STDOUT" "[dotsteward] instance-leak scan: example-term is exempt for this run (contribute start --promote); every other instance term still stops it"
assert_contains "$DS_STDOUT" "[dotsteward] contribute check passed: "
if grep -qixF example-term "$DS_TEST_ROOT/terms.copy"; then
  ds_fail "the terms file holds the promoted name example-term"
fi
for term in example-term-config example-term-state term-theme term-font /home/alice workstation example-notes; do
  grep -qxF -e "$term" "$DS_TEST_ROOT/terms.copy" || ds_fail "the terms file lacks [$term]"
done
# The exemption lives in the run, never in the privacy configuration.
assert_eq "" "$(git -C "$ct_clone" diff --name-only "$base" HEAD -- privacy)" "privacy files of the branch"
if git -C "$ct_clone" grep -qiF example-term "$base" -- privacy; then
  ds_fail "the privacy configuration names the promoted component"
fi

# Every other term still stops the run, the component's settings targets
# (which contain the name) included.
for term in example-term-config example-term-state term-theme /home/alice example-notes; do
  git -C "$ct_clone" reset -q --hard "$base"
  clone_commit modules/components/example-term/README.md "# example-term, see $term" \
    'feat(components): the example-term catalog component'
  assert_exit 4 run_contribute check
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: privacy hard stop" "term $term"
  assert_contains "$DS_STDOUT" "extra-term:" "term $term"
done

# --- runs without --promote ------------------------------------------------------

git -C "$ct_clone" reset -q --hard "$base"
assert_exit 0 run_contribute start --slug plain-run
plain=$(current_id)
state_json | assert_json - 'has("promote") | not'
assert_exit 0 run_contribute status
assert_not_contains "$DS_STDOUT" "promote"
clone_commit modules/components/example-term/README.md '# example-term' \
  'feat(components): the example-term catalog component'
assert_exit 4 run_contribute check
assert_contains "$DS_STDOUT" "extra-term:"
assert_not_contains "$DS_STDOUT" "is exempt for this run"

# The same slug again with --promote: the unfinished run now promotes it.
assert_exit 0 run_contribute start --slug plain-run --promote example-term
assert_contains "$DS_STDOUT" "[dotsteward] resuming run $plain"
assert_contains "$DS_STDOUT" "[dotsteward] promote: example-term"
assert_eq "$plain" "$(current_id)" "current run after the resume"
assert_eq example-term "$(field .promote)" "promote after the resume"
assert_exit 0 run_contribute check
assert_contains "$DS_STDOUT" "example-term is exempt for this run"
# One run promotes one component; the same name again changes nothing.
assert_exit 1 run_contribute start --slug plain-run --promote example-app
assert_contains "$DS_STDERR" "[dotsteward] ERROR: run $plain promotes example-term already; one run promotes one component (abort it and start a new run for example-app)"
assert_exit 0 run_contribute start --slug plain-run --promote example-term
assert_eq example-term "$(field .promote)" "promote after the same name again"
# A plain resume keeps it and names it.
assert_exit 0 run_contribute start --slug promote-term
assert_contains "$DS_STDOUT" "[dotsteward] resuming run $id"
assert_contains "$DS_STDOUT" "[dotsteward] promote: example-term"
assert_eq example-term "$(field .promote)" "promote after a plain resume"

# --- the report -------------------------------------------------------------------

# report_ready ID: the run ID at its last step, report.
report_ready() {
  jq '.step = "report"' "$ct_runs/$1.json" >"$DS_TEST_ROOT/state.json"
  cp "$DS_TEST_ROOT/state.json" "$ct_runs/$1.json"
}

# The report of a run that promotes names the component, in the text and in
# the document.
report_ready "$id"
assert_exit 0 run_contribute report --id "$id"
assert_contains "$DS_STDOUT" "  promoted component: example-term (exempt from the instance-leak scan of this run)"
assert_exit 0 run_contribute report --id "$id" --json
assert_json - '.promote == "example-term"' <<<"$DS_STDOUT"

# A run without --promote reports none.
start_run plain-report
report_ready "$(current_id)"
assert_exit 0 run_contribute report
assert_not_contains "$DS_STDOUT" "promoted component"
assert_exit 0 run_contribute report --json
assert_json - '.promote == null' <<<"$DS_STDOUT"
