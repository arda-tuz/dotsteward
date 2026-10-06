# shellcheck shell=bash
# shellcheck disable=SC2153,SC2154 # DS_* variables come from tests/lib/harness.sh
# Helpers for the skill contract self-tests (tests/skills/selftest). Not a
# test file.
#
# Sourcing this file sources tests/skills/lib/contract.sh and points the
# checks at a synthetic framework root and the stand-in CLI:
#
#   SC_REPO_ROOT  $DS_TEST_ROOT/repo, with LICENSE and VERSION copied from the
#                 framework under test and an empty skills/ directory
#   SC_CLI        tests/fixtures/skills-contract/cli/dotsteward
#   SC_FAKE_CLI_LOG
#                 the stand-in's call log ($DS_TEST_ROOT/fake-cli.log)
#
#   st_skill [NAME] [PARENT]
#       copies tests/fixtures/skills-contract/example-skill to
#       PARENT/NAME (default $SC_REPO_ROOT/skills/example-skill), completes
#       it with the repository LICENSE and the canonical
#       references/classification.md, rewrites the skill name when NAME
#       differs, and prints the directory
#   st_run CHECK [ARG...]
#       resets the findings, runs CHECK, and stores the findings, one per
#       line, in ST_OUT
#   st_expect_clean CHECK [ARG...]
#   st_expect_finding NEEDLE CHECK [ARG...]
#       runs CHECK and asserts no finding, or a finding containing NEEDLE
#   st_replace FILE OLD NEW
#       replaces the first line containing the fixed string OLD with NEW
#       (NEW may hold newlines); fails when OLD is absent

# shellcheck source=tests/skills/lib/contract.sh
source "$DS_REPO_ROOT/tests/skills/lib/contract.sh"

ST_FIXTURES=$DS_REPO_ROOT/tests/fixtures/skills-contract
SC_REPO_ROOT=$DS_TEST_ROOT/repo
SC_CLI=$ST_FIXTURES/cli/dotsteward
SC_FAKE_CLI_LOG=$DS_TEST_ROOT/fake-cli.log
export SC_FAKE_CLI_LOG
mkdir -p "$SC_REPO_ROOT/skills"
cp "$DS_REPO_ROOT/LICENSE" "$DS_REPO_ROOT/VERSION" "$SC_REPO_ROOT/"

st_skill() {
  local name=${1:-example-skill} parent=${2:-$SC_REPO_ROOT/skills} dir
  dir=$parent/$name
  [[ ! -e $dir ]] || ds_fail "st_skill: already exists: $dir"
  mkdir -p "$parent"
  cp -R "$ST_FIXTURES/example-skill" "$dir"
  cp "$DS_REPO_ROOT/LICENSE" "$dir/LICENSE"
  cp "$ST_FIXTURES/classification.md" "$dir/references/classification.md"
  if [[ $name != example-skill ]]; then
    sed -i "s/example-skill/$name/g" "$dir/SKILL.md" "$dir/agents/openai.yaml"
  fi
  printf '%s\n' "$dir"
}

st_run() {
  sc_reset
  "$@"
  ST_OUT=""
  if ((${#SC_FINDINGS[@]})); then
    ST_OUT=$(printf '%s\n' "${SC_FINDINGS[@]}")
  fi
}

st_expect_clean() {
  st_run "$@"
  [[ -z $ST_OUT ]] || ds_fail "expected no finding from [$*], got [$ST_OUT]"
}

st_expect_finding() {
  local needle=$1
  shift
  st_run "$@"
  [[ $ST_OUT == *"$needle"* ]] || ds_fail "expected a finding containing [$needle] from [$*], got [$ST_OUT]"
}

st_replace() {
  local file=$1 old=$2 new=$3 line
  line=$(grep -n -F -m 1 -- "$old" "$file" | cut -d: -f1) || true
  [[ -n $line ]] || ds_fail "st_replace: [$old] not found in $file"
  {
    head -n "$((line - 1))" "$file"
    printf '%s\n' "$new"
    tail -n "+$((line + 1))" "$file"
  } >"$file.new"
  mv "$file.new" "$file"
}
