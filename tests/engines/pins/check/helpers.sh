# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Helpers for the pins engine tests (tests/engines/pins/check). Not a test
# file.
#
# The synthetic instance fixtures/instance declares every rule kind in its
# committed manifest mirror (.dotsteward/manifest.x86_64-linux.json); its
# repo-owned skill example-skill is built at run time with
# ds_fixture_skill_tree (its name contains escapes the privacy scan forbids
# in committed files).
#
#   pins_instance              builds the green instance at $inst (a git
#                              repository with everything committed) and a
#                              pristine copy at $pins_template
#   pins_fresh                 replaces $inst with a copy of $pins_template
#   pins ARG...                `dotsteward --instance $inst pins ARG...`
#   dotsteward ARG...          the framework CLI under test
#   json_edit FILE PYTHON      runs PYTHON with `data` bound to the parsed
#                              JSON of FILE (key order kept), then writes it
#                              back with the lock serializer
#   json_get FILE JQ           jq -c over FILE
#   without_generated FILE     FILE without its generated_at line
#   lib_directory_sha256 DIR   the directory digest of cli/lib/lib.sh
#   check_fails COUNT LINE...  `pins check` exits 1 and prints every LINE on
#                              stderr and the summary of COUNT
#                              inconsistencies, and no traceback
#   check_count                the check count of a green `pins check`
#                              ($DS_STDOUT of the last run)

pins_fixture=$DS_REPO_ROOT/tests/engines/pins/check/fixtures/instance
inst=$DS_TEST_ROOT/inst
pins_template=$DS_TEST_ROOT/pins-template
# shellcheck disable=SC2034 # read by the test files
versions=$inst/versions.lock.json
# shellcheck disable=SC2034 # read by the test files
skills=$inst/agent/skills.lock.json

pins_instance() {
  rm -rf -- "$pins_template" "$inst"
  cp -R -- "$pins_fixture" "$pins_template"
  ds_fixture_skill_tree "$pins_template/agent/skills/example-skill"
  git -C "$pins_template" init -q
  git -C "$pins_template" add -A
  git -C "$pins_template" commit -q -m "synthetic instance"
  cp -a -- "$pins_template" "$inst"
}

pins_fresh() {
  chmod -R u+w -- "$inst" 2>/dev/null || true
  rm -rf -- "$inst"
  cp -a -- "$pins_template" "$inst"
}

dotsteward() {
  "$DS_REPO_ROOT/cli/dotsteward" "$@"
}

pins() {
  "$DS_REPO_ROOT/cli/dotsteward" --instance "$inst" pins "$@"
}

json_edit() {
  local file=$1 code=$2
  python3 - "$file" "$code" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
exec(sys.argv[2], {"data": data})
path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY
}

json_get() {
  jq -c "$2" "$1"
}

without_generated() {
  grep -v '^  "generated_at": ' "$1"
}

lib_directory_sha256() {
  (
    # shellcheck source=cli/lib/lib.sh
    source "$DS_REPO_ROOT/cli/lib/lib.sh"
    directory_sha256 "$1"
  )
}

check_fails() {
  local count=$1 line noun=inconsistencies
  shift
  assert_exit 1 pins check
  for line in "$@"; do
    assert_contains "$DS_STDERR" "$line"$'\n' "failure line"
  done
  ((count == 1)) && noun=inconsistency
  assert_contains "$DS_STDERR" "[pins] $count $noun; " "summary"
  assert_eq "$count" "$(grep -c '^\[pins\] ERROR: ' <<<"$DS_STDERR")" "number of failure lines"
  assert_not_contains "$DS_STDERR" "Traceback"
  assert_eq "" "$DS_STDOUT" "stdout of a failed check"
}

check_count() {
  [[ $DS_STDOUT =~ ^\[pins\]\ All\ pin\ consistency\ checks\ passed\ \(([0-9]+)\ checks\)$ ]] ||
    ds_fail "unexpected success line: [$DS_STDOUT]"
  printf '%s\n' "${BASH_REMATCH[1]}"
}
