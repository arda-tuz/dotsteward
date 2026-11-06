# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Run reports and review.json (dotsteward_cli.report, docs/exit-codes.md): when
# several outcomes hold the heaviest decides the exit code, in the order 4, 1,
# 3, 6, 0; every run leaves a report under <state>/runs/<command>/, ordered by a
# sequence number rather than the clock, and the items that need a person or an
# agent are in <state>/review.json, one file for every command, which stays on the
# machine. Both files are written atomically and validate against their schemas.
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
  and (.started_at | test("Z$")) and (.finished_at | test("Z$")) and .sequence == 1
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
assert_json "$review" '.schema_version == 1 and .status == "pending" and .exit_code == 3
  and .runs == {"upgrade": {"run": "2026-11-03T080000Z-1a2b", "status": "pending", "exit_code": 3}}
  and (.items | length) == 2
  and .items[0] == {"command": "upgrade", "code": "sudo-required", "run": "dotsteward upgrade"}
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
assert_json "$review" '.status == "ok" and .exit_code == 0
  and .items == [{"command": "upgrade", "code": "series-available", "series": "example-2"}]'

# One file for every command. A pending upgrade keeps its items while an observer
# that the end of its lock started leaves its own; the file says the heaviest.
assert_exit 3 report_write '{"items": [{"code": "sudo-required", "run": "dotsteward upgrade"}]}' --command upgrade
assert_exit 0 report_write '{"items": [{"code": "series-available", "pending": false}]}' --command observe
assert_json "$review" '.status == "pending" and .exit_code == 3 and (.runs | keys) == ["observe", "upgrade"]
  and ([.items[] | .command + ":" + .code] | sort) == ["observe:series-available", "upgrade:sudo-required"]'
# A run replaces the items of its own command only: one without items removes them.
assert_exit 3 report_write '{"items": [{"code": "incoming"}]}' --command upgrade
assert_json "$review" '([.items[] | .command + ":" + .code] | sort) == ["observe:series-available", "upgrade:incoming"]'
assert_exit 0 report_write '{"steps": [{"name": "a"}]}' --command upgrade
assert_json "$review" '.status == "ok" and .exit_code == 0 and (.runs | keys) == ["observe"]
  and .items == [{"command": "observe", "code": "series-available"}]'
# Nothing left, no file.
assert_exit 0 report_write '{"steps": [{"name": "a"}]}' --command observe
[[ ! -e $review ]] || ds_fail "the last command without items left the review"

# Commands that end at the same time all stay in the file.
pids=()
for number in 1 2 3 4 5 6 7 8 9 10 11 12; do
  report_write "{\"items\": [{\"code\": \"incoming\", \"id\": \"item-$number\"}]}" --command "command-$number" >/dev/null &
  pids+=($!)
done
for pid in "${pids[@]}"; do
  wait "$pid" || [[ $? == 3 ]] || ds_fail "a report of the concurrent commands failed"
done
assert_json "$review" '(.items | length) == 12 and (.runs | length) == 12'
for number in 1 2 3 4 5 6 7 8 9 10 11 12; do
  assert_exit 0 report_write '{"steps": [{"name": "a"}]}' --command "command-$number"
done
[[ ! -e $review ]] || ds_fail "the review outlived the items of the concurrent commands"

# The status of a child is an outcome of the run: any status but 0, 3, 4 and 6
# fails it and stays in the step, so a long run never loses its report to one.
assert_exit 1 report_write '{"steps": [{"name": "rebuild", "code": 137}]}' --command upgrade
assert_json "$(jq -r .report <<<"$DS_STDOUT")" '.status == "failed" and .exit_code == 1
  and .steps == [{"name": "rebuild", "status": "failed", "exit_status": 137}]'
assert_exit 1 report_write '{"steps": [{"name": "settings", "code": 2}]}' --command upgrade
assert_json "$(jq -r .report <<<"$DS_STDOUT")" '.steps[0].status == "failed" and .steps[0].exit_status == 2'
assert_exit 6 report_write '{"steps": [{"name": "fetch", "code": 6}]}' --command upgrade
assert_json "$(jq -r .report <<<"$DS_STDOUT")" '.steps == [{"name": "fetch", "status": "partial"}]'

# Bad input is a refusal, with the file as it was.
assert_exit 1 report_write 'not json' --command upgrade
assert_contains "$DS_STDERR" "[dotsteward] ERROR: "
assert_exit 1 report_write '{"items": [{"id": "no-code"}]}' --command upgrade
assert_exit 1 report_write '{"steps": [{"name": "a"}]}' --command 'not/a/name'
assert_exit 2 internal report write --state-root "$state" </dev/null
# The fields the report keeps for itself, and values of the wrong type.
assert_exit 1 report_write '{"steps": [{"name": "a", "status": "ok"}]}' --command upgrade
assert_contains "$DS_STDERR" "invalid run report"
assert_exit 1 report_write '{"steps": [{"name": "a", "code": true}]}' --command upgrade
assert_exit 1 report_write '{"steps": [{"name": "a", "code": "1"}]}' --command upgrade
assert_exit 1 report_write '{"items": [{"code": "a", "pending": "false"}]}' --command upgrade
assert_exit 1 report_write '{"items": [{"code": "a", "command": "other"}]}' --command upgrade
assert_exit 1 report_write '{"items": [{"code": "Not A Code"}]}' --command upgrade
# Text that is no valid Unicode, from a file name perhaps, is no reason to lose a report.
assert_exit 0 report_write '{"steps": [{"name": "a", "path": "/tmp/\ud800"}]}' --command upgrade
core_python -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$(jq -r .report <<<"$DS_STDOUT")" ||
  ds_fail "a report with a lone surrogate is no JSON text"

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
# Signals add up over the protected steps of a run; a step without any changes nothing.
run.mark_interrupted(())
run.mark_interrupted(("SIGTERM", "SIGINT"))
# A value without a JSON form is written as text at the end of a long run, not lost.
run.step("list", report.OK, where=Path("/synthetic/path"))
paths = run.write()
written = json.loads(paths.report.read_text(encoding="utf-8"))
assert written["steps"] == [
    {"name": "gate", "status": "partial", "detail": "offline"},
    {"name": "list", "status": "ok", "where": "/synthetic/path"},
], written
assert written["data"] == {"unpublished_commits": ["abc"]}
assert written["interrupted"] == ["SIGINT", "SIGTERM"]
assert written["exit_code"] == 3
assert paths.review == state / "review.json"
mine = [item for item in report.load_review(state)["items"] if item["command"] == "apply"]
assert mine[0] == {"command": "apply", "code": "publish-race", "commit": "abc"}, mine

# The exit status of a child as an outcome.
for status, outcome in ((0, 0), (3, 3), (4, 4), (6, 6), (1, 1), (2, 1), (5, 1), (127, 1), (137, 1)):
    assert report.outcome_of(status) == outcome, status
for wrong in (True, "1", None, 1.0):
    try:
        report.outcome_of(wrong)
    except ValueError:
        pass
    else:
        raise AssertionError(f"{wrong!r} counts as an exit status")
try:
    report.combine([True])
except ValueError:
    pass
else:
    raise AssertionError("combine took a boolean")
for call in (
    lambda: run.step("x", report.OK, status="ok"),
    lambda: run.item("x", command="other"),
    lambda: run.item("x", pending="false"),
    lambda: run.item("Not A Code"),
):
    try:
        call()
    except ValueError:
        pass
    else:
        raise AssertionError("a reserved field or a wrong type was accepted")

# The last report of a command is there for the next run; a damaged one is skipped.
assert report.load_last(state, "apply")["run"] == run.run
assert report.load_last(state, "never-ran") is None
newer = state / "runs" / "apply" / "9999-01-01T000000Z-ffff.json"
newer.write_text("{ damaged", encoding="utf-8")
assert report.load_last(state, "apply")["run"] == run.run
newer.unlink()

# The last report does not depend on the clock. A machine whose clock was ahead left
# reports from the future; the next run, with the clock right, is the last one all
# the same, and retention does not delete what was just written.
for number in range(report.KEEP_REPORTS):
    report.RunReport("clock", state, run=f"2099-01-01T{number:06d}Z-aaaa").write()
behind = report.RunReport("clock", state, run="2026-01-01T000000Z-bbbb")
path = behind.write().report
assert path.exists(), "the report just written was removed"
assert report.load_last(state, "clock")["run"] == behind.run
names = sorted(entry.name for entry in (state / "runs" / "clock").glob("*.json"))
assert len(names) == report.KEEP_REPORTS and "2099-01-01T000000Z-aaaa.json" not in names, names
short = report.RunReport("clock", state, run="0")
assert short.write().report.exists()
assert report.load_last(state, "clock")["run"] == "0"

# Runs in the same second: the last one is the last one.
for _ in range(40):
    same = report.RunReport("same-second", state)
    same.write()
    assert report.load_last(state, "same-second")["run"] == same.run

# Only the newest reports of a command stay.
for number in range(report.KEEP_REPORTS + 5):
    old = report.RunReport("keep", state, run=f"2026-01-01T{number:06d}Z-aaaa")
    old.write()
kept = sorted(path.name for path in (state / "runs" / "keep").glob("*.json"))
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

# Concurrent runs of one command all get a number of their own.
for _ in 1 2 3 4 5 6; do
  report_write '{"steps": [{"name": "a"}]}' --command parallel >/dev/null &
done
wait
assert_eq '1 2 3 4 5 6' "$(jq -s -r 'map(.sequence) | sort | map(tostring) | join(" ")' "$state"/runs/parallel/*.json)" "the numbers"

# --- the documents ---------------------------------------------------------------------------

page=$DS_REPO_ROOT/docs/exit-codes.md
for code in "| 0 |" "| 1 |" "| 3 |" "| 4 |" "| 6 |"; do
  grep -qF -- "$code" "$page" || ds_fail "docs/exit-codes.md does not explain $code"
done
assert_contains "$(<"$page")" "4, 1, 3, 6, 0"
assert_contains "$(<"$page")" 'review.json'
assert_contains "$(<"$page")" '5: upstream main moved'
assert_not_contains "$(<"$page")" '3 and 4 mean the same here'
