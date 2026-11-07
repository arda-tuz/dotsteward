# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# What the agent reads: a subject is one line, so -m cannot add a second trace line; a refusal of
# `maintain begin --json` is still one JSON document; a fast-forward that would overwrite local
# changes names their paths and a way out that never stashes.
# shellcheck source=tests/apply/helpers.sh
source "$DS_REPO_ROOT/tests/apply/helpers.sh"

base=$(remote_oid)
edit "x"
clear_log
assert_exit 2 apply -m $'docs: x\n\nDotsteward-Machine: other-host' --activate --publish
assert_contains "$DS_STDERR" "one line"
assert_exit 2 apply -m $'docs: x\r' --activate --publish
assert_eq "" "$(<"$UP_LOG")" "no command ran"
assert_eq "$base" "$(head_oid)"
git -C "$up_inst" checkout -q -- docs/guide.md

# A refusal of begin --json: the document says why.
git -C "$up_inst" switch -q -c elsewhere
assert_exit 1 begin --json
assert_stdout_json '.open == false and (.refused | contains("elsewhere"))'
git -C "$up_inst" switch -q main

# Local changes that the fast-forward would overwrite.
push_from_elsewhere "a commit of another machine"
printf 'local overlap\n' >>"$up_inst/docs/guide.md"
assert_exit 1 begin --json
assert_stdout_json '.open == false and (.refused | contains("docs/guide.md"))'
assert_contains "$DS_STDERR" "docs/guide.md"
assert_not_contains "$DS_STDERR" "stash"
assert_not_contains "$DS_STDOUT" "stash"
assert_contains "$(<"$up_inst/docs/guide.md")" "local overlap"
