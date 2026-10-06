# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# G5, the candidate tree ([gate] I8): the gate validates the tree that
# `git add -A && git write-tree` would write (staged and unstaged changes,
# ignored files left out), computed in a throw-away index: the real index,
# HEAD and the working tree are untouched and no temporary directory is left.
# The tree id does not depend on whether the changes are committed.
# shellcheck source=tests/cli/gate/helpers.sh
source "$DS_REPO_ROOT/tests/cli/gate/helpers.sh"

ds_use_stubs nix curl
serve_cache

mkdir -p "$gate_inst/notes" "$gate_inst/ignored"
printf 'staged\n' >"$gate_inst/notes/staged.txt"
git -C "$gate_inst" add notes/staged.txt
printf 'unstaged\n' >>"$gate_inst/docs/guide.md"
printf 'ignored\n' >"$gate_inst/ignored/cache.bin"
chmod 0755 "$gate_inst/components/example-app/version.txt"

expected=$(add_tree_oid)
index_before=$(sha256sum <"$gate_inst/.git/index")
status_before=$(git -C "$gate_inst" status --porcelain=v2 --ignored)
head_before=$(head_oid)

assert_exit 0 run_gate --scope maintain
assert_eq "$expected" "$(jq -r .tree_oid "$gate_validation")"
assert_contains "$(tail -n 1 <<<"$DS_STDOUT")" "\"tree_oid\":\"$expected\""
assert_eq "$index_before" "$(sha256sum <"$gate_inst/.git/index")" "the real index changed"
assert_eq "$status_before" "$(git -C "$gate_inst" status --porcelain=v2 --ignored)"
assert_eq "$head_before" "$(head_oid)"
assert_eq "" "$(temp_dirs)" "temporary directories left behind"
listed=$(git -C "$gate_inst" ls-tree -r --name-only "$expected")
[[ $'\n'$listed != *$'\n'ignored/* ]] || ds_fail "the ignored file is part of the validated tree"
[[ $(git -C "$gate_inst" ls-tree "$expected" components/example-app/version.txt) == 100755* ]] ||
  ds_fail "the mode change is not part of the validated tree"

# Committing the same changes keeps the tree: the gate answers from the memo.
git -C "$gate_inst" add -A
git -C "$gate_inst" commit -q -m "docs: commit the candidate"
assert_eq "$expected" "$(git -C "$gate_inst" rev-parse 'HEAD^{tree}')"
: >"$DS_CALL_LOG"
assert_exit 0 run_gate --scope maintain
assert_json - '.memo == true' <<<"$(tail -n 1 <<<"$DS_STDOUT")"
assert_eq "" "$(fake_calls)"
