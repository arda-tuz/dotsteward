# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# `dotsteward contribute commit -m SUBJECT [-m PARAGRAPH...] [--test]` and the
# commit hooks of the framework (.githooks/commit-msg and .githooks/pre-commit,
# active in the clone through core.hooksPath=.githooks from setup).
#
# commit stages everything in the run's clone and commits with the clone's
# identity and UTC dates, whatever the environment says; it refuses a
# subject that is not a conventional commit (the types of
# commit.conventional_types), a trailer block or an attribution line, a
# commit before the reproduction failed (--test marks the reproduction, a
# test subject) and after publish; a commit after a passing check sends the
# run back to check. A plain `git commit` in the clone meets the same rules
# in the hooks: commit-msg refuses the message, pre-commit refuses author
# or committer dates outside UTC (TZ, GIT_AUTHOR_DATE, GIT_COMMITTER_DATE,
# --date) and names `dotsteward contribute commit`.
# shellcheck source=tests/contribute/local/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/local/helpers.sh"

rules=$DS_REPO_ROOT/cli/lib/commit-rules.sh
for hook in commit-msg pre-commit; do
  [[ -f $DS_REPO_ROOT/.githooks/$hook ]] || ds_fail "missing hook: .githooks/$hook"
  [[ -x $DS_REPO_ROOT/.githooks/$hook ]] || ds_fail "the hook .githooks/$hook is not executable"
  if git -C "$DS_REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    mode=$(git -C "$DS_REPO_ROOT" ls-files -s -- ".githooks/$hook" | cut -d ' ' -f 1)
    [[ -z $mode ]] || assert_eq 100755 "$mode" "the hook $hook is executable in the index"
  fi
done
[[ -f $rules ]] || ds_fail "missing cli/lib/commit-rules.sh"

# The rules use the conventional types of the CLI and refuse every forbidden
# message line of the privacy policy.
types=$("$DS_REPO_ROOT/cli/dotsteward" --instance "$ct_inst" context --json | jq -r '.commit.conventional_types | join(" ")')
# shellcheck disable=SC2016 # expanded by the inner bash
assert_eq "$types" "$(bash -c 'source "$1"; printf "%s" "${COMMIT_RULES_TYPES[*]}"' _ "$rules")" \
  "the conventional types of the commit rules"
# shellcheck disable=SC2016 # expanded by the inner bash
forbidden=$(bash -c 'source "$1"; printf "%s\n" "${COMMIT_RULES_FORBIDDEN_LINES[@]}"' _ "$rules")
while IFS= read -r pattern; do
  grep -qxF -e "$pattern" <<<"$forbidden" || ds_fail "the commit rules do not refuse the policy's forbidden line [$pattern]"
done < <(python3 -c 'import sys, tomllib; print("\n".join(tomllib.load(open(sys.argv[1], "rb"))["commits"]["forbidden_lines"]))' \
  "$DS_REPO_ROOT/privacy/policy.toml")

# The synthetic framework ships the real commit hooks and their rules, as the
# framework does.
work=$DS_TEST_ROOT/hooks-src
git clone -q "$ct_upstream_bare" "$work"
mkdir -p "$work/.githooks" "$work/cli/lib"
cp "$DS_REPO_ROOT/.githooks/commit-msg" "$DS_REPO_ROOT/.githooks/pre-commit" "$work/.githooks/"
cp "$rules" "$work/cli/lib/commit-rules.sh"
git -C "$work" add -A
git -C "$work" commit -q -m "feat: the commit hooks"
git -C "$work" push -q origin HEAD:main

setup_owner
start_run add-greeting
id=$(current_id)

field() {
  state_json | jq -r "$1"
}

# commit_as ARG...: `contribute commit` with a time zone, dates and an
# identity of another machine in the environment.
commit_as() {
  env TZ=XYZ-5 GIT_AUTHOR_DATE='2026-01-01T12:00:00+0500' GIT_COMMITTER_DATE='2026-01-01T12:00:00+0500' \
    GIT_AUTHOR_NAME=someone GIT_AUTHOR_EMAIL=someone@example.com \
    GIT_COMMITTER_NAME=someone GIT_COMMITTER_EMAIL=someone@example.com \
    "$DS_REPO_ROOT/cli/dotsteward" --instance "$ct_inst" contribute commit "$@" </dev/null
}

cat >"$ct_clone/tests/example/test-greeting.sh" <<'EOF'
#!/usr/bin/env bash
# Fails until the greeting exists.
set -euo pipefail
test "$(cat greeting.txt)" = hello
EOF

# --- refusals -------------------------------------------------------------------

# Nothing is committed before the reproduction failed.
assert_exit 1 run_contribute commit -m 'test(example): expect the greeting' --test
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the reproduction has not failed yet: run dotsteward contribute check --expect-fail <test path> first, then commit the test with --test"
assert_exit 0 run_contribute check --expect-fail tests/example/test-greeting.sh
assert_eq fix "$(field .step)" "step after the reproduction"
base=$(git -C "$ct_clone" rev-parse HEAD)

for subject in 'Add the greeting test' 'test: ' 'tests(example): expect it' 'test(Example): expect it' \
  'test(example) expect it' 'WIP test(example): expect it'; do
  assert_exit 1 run_contribute commit -m "$subject" --test
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: not a conventional commit subject: $subject"
done
assert_exit 1 run_contribute commit -m $'test(example): expect\nthe greeting' --test
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the subject is one line; give the body with further -m options"
assert_exit 1 run_contribute commit -m 'feat(example): the greeting test' --test
assert_contains "$DS_STDERR" "[dotsteward] ERROR: --test commits the reproduction test: its subject is test(AREA): ..."

# Trailers and attribution lines, anywhere in the message.
assert_exit 1 run_contribute commit -m 'test(example): expect the greeting' -m 'Co-Authored-By: Someone <someone@example.com>' --test
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the message ends with trailers (Co-Authored-By): framework commits carry none"
assert_exit 1 run_contribute commit -m 'test(example): expect the greeting' -m 'Refs: 12' --test
assert_contains "$DS_STDERR" "the message ends with trailers (Refs)"
assert_exit 1 run_contribute commit -m 'test(example): expect the greeting' -m 'Claude-Session: https://example.invalid/s' -m 'More text.' --test
assert_contains "$DS_STDERR" "[dotsteward] ERROR: message line 3 matches the forbidden line pattern ^Claude-Session:"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: commit refused"
assert_eq "$base" "$(git -C "$ct_clone" rev-parse HEAD)" "HEAD after the refusals"
assert_eq "" "$(git -C "$ct_clone" diff --cached --name-only)" "the refusals stage nothing"

# --- the reproduction and the fix -----------------------------------------------

# Everything is staged; the clone's identity and UTC dates win over the
# environment; the message is exactly the subject.
assert_exit 0 commit_as -m 'test(example): expect the greeting' --test
head=$(git -C "$ct_clone" rev-parse HEAD)
assert_contains "$DS_STDOUT" "[dotsteward] committed ${head:0:12} on fix/add-greeting: test(example): expect the greeting"
assert_contains "$DS_STDOUT" "[dotsteward] next: fix the cause, then: dotsteward contribute commit -m 'fix(AREA): what changed'"
assert_eq 'test(example): expect the greeting' "$(git -C "$ct_clone" log -1 --format=%B)" "message"
assert_eq "dotsteward-test <$CT_NOREPLY> dotsteward-test <$CT_NOREPLY>" \
  "$(git -C "$ct_clone" log -1 --format='%an <%ae> %cn <%ce>')" "identity"
assert_eq "+0000 +0000" "$(git -C "$ct_clone" log -1 --format='%ad %cd' --date=format:%z)" "time zones"
assert_eq "" "$(git -C "$ct_clone" log -1 --format='%(trailers)')" "trailers"
assert_eq tests/example/test-greeting.sh "$(git -C "$ct_clone" show --name-only --format= HEAD)" "files of the commit"
assert_eq "" "$(git -C "$ct_clone" status --porcelain)" "the clone after the commit"
assert_eq fix "$(field .step)" "step after the test commit"

assert_exit 1 run_contribute commit -m 'feat(example): greet'
assert_contains "$DS_STDERR" "[dotsteward] ERROR: nothing to commit in $ct_clone"

# Further -m options are the paragraphs of the body; new files are staged.
printf 'hello\n' >"$ct_clone/greeting.txt"
assert_exit 0 run_contribute commit -m 'feat(example): greet' -m 'The greeting file holds the greeting.'
assert_eq $'feat(example): greet\n\nThe greeting file holds the greeting.' "$(git -C "$ct_clone" log -1 --format=%B)" "message with a body"
assert_contains "$DS_STDOUT" "[dotsteward] next: dotsteward contribute check"

# A commit after a passing check: the run goes back to check.
assert_exit 0 run_contribute check
assert_eq trial "$(field .step)" "step after the gate"
printf 'notes\n' >"$ct_clone/NOTES.md"
assert_exit 0 run_contribute commit -m 'docs(example): note the greeting'
assert_contains "$DS_STDOUT" "[dotsteward] the run goes back to check: the framework gate passed for an earlier commit"
state_json | assert_json - '.step == "check" and .test_sha == null and .tested_tree == null'

# After publish a change is a new run.
jq '.step = "release"' "$ct_runs/$id.json" >"$DS_TEST_ROOT/state.json"
cp "$DS_TEST_ROOT/state.json" "$ct_runs/$id.json"
printf 'late\n' >"$ct_clone/late.md"
assert_exit 1 run_contribute commit -m 'docs(example): a late note'
assert_contains "$DS_STDERR" "[dotsteward] ERROR: run $id is published already (step release): a further change is a new run (dotsteward contribute start --slug SLUG)"
rm -f "$ct_clone/late.md"
jq '.step = "check"' "$ct_runs/$id.json" >"$DS_TEST_ROOT/state.json"
cp "$DS_TEST_ROOT/state.json" "$ct_runs/$id.json"

# --- the hooks ------------------------------------------------------------------

head=$(git -C "$ct_clone" rev-parse HEAD)
printf 'a\n' >"$ct_clone/a.txt"
git -C "$ct_clone" add a.txt

# pre-commit: dates outside UTC, from the time zone or the environment.
for setting in TZ=XYZ-2 GIT_AUTHOR_DATE=2026-01-01T12:00:00+0200 GIT_COMMITTER_DATE=2026-01-01T12:00:00-0500; do
  assert_exit 1 env "$setting" git -C "$ct_clone" commit -q -m 'feat(example): a'
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: pre-commit: " "$setting"
  assert_contains "$DS_STDERR" "not +0000 (UTC)" "$setting"
  assert_contains "$DS_STDERR" "commit with: dotsteward contribute commit" "$setting"
done
assert_exit 1 git -C "$ct_clone" commit -q --date=2026-01-01T12:00:00+0100 -m 'feat(example): a'
assert_contains "$DS_STDERR" "[dotsteward] ERROR: pre-commit: the author date would carry the offset +0100, not +0000 (UTC)"

# commit-msg: the subject, trailer blocks and attribution lines.
assert_exit 1 git -C "$ct_clone" commit -q -m 'Add a'
assert_contains "$DS_STDERR" "[dotsteward] ERROR: commit-msg: the subject is not a conventional commit"
assert_contains "$DS_STDERR" "commit with: dotsteward contribute commit"
assert_exit 1 git -C "$ct_clone" commit -q -m 'feat(example): a' -m 'Signed-off-by: Someone <someone@example.com>'
assert_contains "$DS_STDERR" "[dotsteward] ERROR: commit-msg: the message ends with trailers (Signed-off-by)"
assert_exit 1 git -C "$ct_clone" commit -q -m 'feat(example): a' -m 'Refs: 12' -m 'Reviewed-by: Someone <someone@example.com>'
assert_contains "$DS_STDERR" "the message ends with trailers (Reviewed-by)"
assert_exit 1 git -C "$ct_clone" commit -q -m 'feat(example): a' -m 'co-authored-by: Someone <someone@example.com>' -m 'Text after it.'
assert_contains "$DS_STDERR" "[dotsteward] ERROR: commit-msg: message line 3 matches the forbidden line pattern ^Co-Authored-By:"
assert_exit 1 git -C "$ct_clone" commit -q -m 'feat(example): a' -m 'Generated with [Claude Code](https://example.com)' -m 'Text after it.'
assert_contains "$DS_STDERR" 'matches the forbidden line pattern Generated with \[Claude Code\]'
assert_exit 1 git -C "$ct_clone" commit -q -m 'feat(example): a' -m 'Claude-Session: https://example.invalid/s'
assert_contains "$DS_STDERR" "trailers (Claude-Session)"
assert_contains "$DS_STDERR" "forbidden line pattern ^Claude-Session:"
assert_eq "$head" "$(git -C "$ct_clone" rev-parse HEAD)" "the refused commits do not exist"

# A conventional message passes, also with a breaking-change mark, a colon
# inside a body paragraph and comment lines from an editor.
assert_exit 0 git -C "$ct_clone" commit -q -m 'feat(example)!: a' -m 'Why: the old file was wrong, so a new one replaces it.' \
  -m 'Closing words.'
printf 'b\n' >"$ct_clone/b.txt"
git -C "$ct_clone" add b.txt
cat >"$DS_TEST_ROOT/editor" <<EOF
#!$BASH
printf 'docs(example): b\n\n# Please enter the commit message for your changes.\n# Co-Authored-By: Someone <someone@example.com>\n' >"\$1"
EOF
chmod 0755 "$DS_TEST_ROOT/editor"
assert_exit 0 env GIT_EDITOR="$DS_TEST_ROOT/editor" git -C "$ct_clone" commit -q
assert_eq 'docs(example): b' "$(git -C "$ct_clone" log -1 --format=%B)" "message written in the editor"

# The hooks refuse when their rules are missing next to them.
rm -f "$ct_clone/cli/lib/commit-rules.sh"
printf 'c\n' >"$ct_clone/c.txt"
git -C "$ct_clone" add c.txt
assert_exit 1 git -C "$ct_clone" commit -q -m 'docs(example): c'
assert_contains "$DS_STDERR" "the commit rules cli/lib/commit-rules.sh are missing next to the hook; commit refused"
git -C "$ct_clone" checkout -q -- cli/lib/commit-rules.sh
git -C "$ct_clone" reset -q
rm -f "$ct_clone/c.txt"

assert_eq "" "$(temp_leftovers)" "temporary files left behind"
