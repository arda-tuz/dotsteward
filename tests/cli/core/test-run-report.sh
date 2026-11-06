# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Run reports and review.json (dotsteward_cli.report, docs/exit-codes.md): when
# several outcomes hold the heaviest decides the exit code, in the order 4, 1,
# 3, 6, 0; every run leaves a report under <state>/runs/<command>/, and the
# items that need a person or an agent are in <state>/review.json, which stays
# on the machine. Both files are written atomically and validate against their
# schemas.
# shellcheck source=tests/cli/core/helpers.sh
source "$DS_REPO_ROOT/tests/cli/core/helpers.sh"

state=$DS_TEST_ROOT/state-under-test
review=$state/review.json

# report_write JSON ARG...: the internal command with JSON on standard input.
report_write() {
  local input=$1
  shift
  internal report write --state-root "$state" "$@" <<<"$input"
}

# --- the order of the exit codes -----------------------------------------------------

assert_exit 0 internal report combine
assert_eq 0 "$DS_STDOUT"
for pair in "0:0" "0 0:0" "6:6" "0 6:6" "3 6:3" "6 3:3" "1 3:1" "3 1:1" "1 3 6 0:1" "4:4" "4 1:4" "1 4:4" "0 6 3 1 4:4"; do
  codes=${pair%:*}
  # shellcheck disable=SC2086 # one code per word
  assert_eq "${pair##*:}" "$(internal report combine $codes)" "combine $codes"
done
# 2 is a usage error and 5 means something else in `contribute`: no outcome.
assert_exit 1 internal report combine 5
assert_contains "$DS_STDERR" "[dotsteward] ERROR: not an outcome: 5"
assert_exit 1 internal report combine 2

# --- a clean run ------------------------------------------------------------------------

assert_exit 0 report_write '{"steps": [{"name": "lock"}, {"name": "fetch", "code": 0}]}' --command upgrade
report=$(<<<"$DS_STDOUT" jq -r .report)
[[ $report == "$state"/runs/upgrade/*.json ]] || ds_fail "the report is at $report"
assert_json "$report" '.schema_version == 1 and .command == "upgrade" and .status == "ok" and .exit_code == 0
  and (.run | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z-[0-9a-f]{4}$"))
  and (.started_at | test("Z$")) and (.finished_at | test("Z$"))
  and .steps == [{"name": "lock", "status": "ok"}, {"name": "fetch", "status": "ok"}] and .items == []'
[[ ! -e $review ]] || ds_fail "a clean run wrote review.json"
assert_file_mode "$state" 700
assert_file_mode "$state/runs" 700
assert_file_mode "$report" 600

# --- exit code precedence, through the steps of a run -------------------------------------

# outcome STEP_CODES EXPECTED: a run with steps of these codes exits EXPECTED.
outcome() {
  local steps='' code
  for code in $1; do
    steps+="${steps:+,}{\"name\": \"step-$code\", \"code\": $code}"
  done
  assert_exit "$2" report_write "{\"steps\": [$steps]}" --command upgrade
  assert_json - ".exit_code == $2" <<<"$(jq -c . "$(jq -r .report <<<"$DS_STDOUT")")"
}
outcome "0 6" 6
outcome "6 3" 3
outcome "3 1" 1
outcome "1 4" 4
outcome "4 1 3 6 0" 4
outcome "0 3 6" 3
assert_json - '.status == "privacy-stop"' <<<"$(report_write '{"steps": [{"name": "a", "code": 4}]}' --command upgrade || true)"
assert_json - '.status == "failed"' <<<"$(report_write '{"steps": [{"name": "a", "code": 1}]}' --command upgrade || true)"
assert_json - '.status == "partial"' <<<"$(report_write '{"steps": [{"name": "a", "code": 6}]}' --command upgrade || true)"
assert_json - '.status == "pending"' <<<"$(report_write '{"steps": [{"name": "a", "code": 3}]}' --command upgrade || true)"
assert_json - '.status == "ok"' <<<"$(report_write '{"steps": [{"name": "a"}]}' --command upgrade)"

# --- review.json --------------------------------------------------------------------------

# The example of the design: a pending decision and a sudo step.
items='{"steps": [{"name": "apt-plan-commit", "code": 3}], "items": [
  {"code": "sudo-required", "run": "dotsteward upgrade"},
  {"code": "apt-denied", "class": "constrained-major", "packages": ["example-server-19"],
   "pulled_by": "example-meta", "accept": "dotsteward upgrade --accept install:example-server-19"}
]}'
assert_exit 3 report_write "$items" --command upgrade --run 2026-11-03T080000Z-1a2b
assert_json "$review" '.schema_version == 1 and .run == "2026-11-03T080000Z-1a2b" and .status == "pending" and .exit_code == 3
  and .command == "upgrade" and (.items | length) == 2
  and .items[0] == {"code": "sudo-required", "run": "dotsteward upgrade"}
  and .items[1].code == "apt-denied" and .items[1].packages == ["example-server-19"]'
assert_file_mode "$review" 600
assert_json "$state/runs/upgrade/2026-11-03T080000Z-1a2b.json" '(.items | length) == 2 and .status == "pending"'

# An item needs a person or an agent, so it is pending by itself; a heavier
# outcome still wins, and the review shows the exit code of the run.
assert_exit 3 report_write '{"items": [{"code": "incoming", "id": "skill-a"}]}' --command upgrade
assert_exit 1 report_write '{"steps": [{"name": "gate", "code": 1}], "items": [{"code": "incoming"}]}' --command upgrade
assert_json "$review" '.status == "failed" and .exit_code == 1 and .items[0].code == "incoming"'

# A note does not stop anything: it is in the review, and the run exits 0.
assert_exit 0 report_write '{"items": [{"code": "series-available", "pending": false, "series": "example-2"}]}' --command upgrade
assert_json "$review" '.status == "ok" and .exit_code == 0 and .items == [{"code": "series-available", "series": "example-2"}]'

# The next run without items of this command clears its review, which a run of
# another command leaves alone.
assert_exit 3 report_write '{"items": [{"code": "incoming"}]}' --command upgrade
assert_exit 0 report_write '{"steps": [{"name": "a"}]}' --command observe
[[ -f $review ]] || ds_fail "another command removed the review"
assert_exit 0 report_write '{"steps": [{"name": "a"}]}' --command upgrade
[[ ! -e $review ]] || ds_fail "a clean run left the old review"

# Bad input is a refusal, with the file as it was.
assert_exit 1 report_write 'not json' --command upgrade
assert_contains "$DS_STDERR" "[dotsteward] ERROR: "
assert_exit 1 report_write '{"steps": [{"name": "a", "code": 5}]}' --command upgrade
assert_contains "$DS_STDERR" "not an outcome: 5"
assert_exit 1 report_write '{"items": [{"id": "no-code"}]}' --command upgrade
assert_exit 1 report_write '{"steps": [{"name": "a"}]}' --command 'not/a/name'
assert_exit 2 internal report write --state-root "$state" </dev/null

# --- the schemas -------------------------------------------------------------------------

python=${DS_JSONSCHEMA_PYTHON:-}
if [[ -n $python ]]; then
  assert_exit 3 report_write "$items" --command upgrade --run 2026-11-03T080001Z-1a2b
  "$python" -I - "$DS_REPO_ROOT/schema" "$review" "$state/runs/upgrade/2026-11-03T080001Z-1a2b.json" <<'PY' ||
import json
import sys

import jsonschema

schemas, review, report = sys.argv[1:]
for schema, document in ((f"{schemas}/review.schema.json", review), (f"{schemas}/run-report.schema.json", report)):
    with open(schema, encoding="utf-8") as handle:
        checker = jsonschema.Draft202012Validator(json.load(handle))
    with open(document, encoding="utf-8") as handle:
        checker.validate(json.load(handle))
PY
    ds_fail "a document does not validate against its schema"
fi

# --- the interface for Python --------------------------------------------------------------

core_python - "$state" <<'PY' || ds_fail "the Python interface"
import json
import os
import sys
from pathlib import Path

from dotsteward_cli import report

state = Path(sys.argv[1])
assert report.combine([report.OK, report.PARTIAL, report.PENDING]) == report.PENDING
assert report.status_name(report.PRIVACY_STOP) == "privacy-stop"

run = report.RunReport("apply", state)
assert run.exit_code == report.OK and run.status == "ok"
run.step("gate", report.PARTIAL, detail="offline")
run.item("publish-race", commit="abc")
run.item("analysis", pending=False, count=3)
run.data["unpublished_commits"] = ["abc"]
run.mark_interrupted(("SIGINT",))
assert run.exit_code == report.PENDING and run.status == "pending"
paths = run.write()
written = json.loads(paths.report.read_text(encoding="utf-8"))
assert written["steps"] == [{"name": "gate", "status": "partial", "detail": "offline"}], written
assert written["data"] == {"unpublished_commits": ["abc"]}
assert written["interrupted"] == ["SIGINT"]
assert written["exit_code"] == 3
assert paths.review == state / "review.json"
assert report.load_review(state)["items"][0] == {"code": "publish-race", "commit": "abc"}

# The last report of a command is there for the next run; a damaged one is skipped.
assert report.load_last(state, "apply")["run"] == run.run
assert report.load_last(state, "never-ran") is None
newer = state / "runs" / "apply" / "9999-01-01T000000Z-ffff.json"
newer.write_text("{ damaged", encoding="utf-8")
assert report.load_last(state, "apply")["run"] == run.run
newer.unlink()

# Only the newest reports of a command stay.
for number in range(report.KEEP_REPORTS + 5):
    old = report.RunReport("keep", state, run=f"2026-01-01T{number:06d}Z-aaaa")
    old.write()
kept = sorted(path.name for path in (state / "runs" / "keep").iterdir())
assert len(kept) == report.KEEP_REPORTS, len(kept)
assert kept[-1] == f"2026-01-01T{report.KEEP_REPORTS + 4:06d}Z-aaaa.json", kept[-1]

try:
    report.RunReport("not/a/name", state)
except ValueError:
    pass
else:
    raise AssertionError("a bad command name was accepted")
os.remove(state / "review.json")
assert report.load_review(state) is None
PY

# --- the documents ---------------------------------------------------------------------------

page=$DS_REPO_ROOT/docs/exit-codes.md
for code in "| 0 |" "| 1 |" "| 3 |" "| 4 |" "| 6 |"; do
  grep -qF -- "$code" "$page" || ds_fail "docs/exit-codes.md does not explain $code"
done
assert_contains "$(<"$page")" "4, 1, 3, 6, 0"
assert_contains "$(<"$page")" 'review.json'
assert_contains "$(<"$page")" '5: upstream main moved'
