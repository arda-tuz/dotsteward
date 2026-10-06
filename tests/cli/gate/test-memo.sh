# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# G6, the memo (SPEC 6.2, [gate] I9): a passed record answers the gate when
# the tree, `nix --version`, the gate version (the framework VERSION), the
# framework override and the denylist digest are all equal; scope and root
# are not part of the key. A memo answer runs no step, keeps the log and
# prints {result, tree_oid, scope, validated_at, total_seconds, memo: true}.
# --force reruns; a failed run keeps the previous record; a record of the
# older schema 1.0 (without the new key fields) never answers.
# shellcheck source=tests/cli/gate/helpers.sh
source "$DS_REPO_ROOT/tests/cli/gate/helpers.sh"

ds_use_stubs nix curl
serve_cache

memo_hit() {
  : >"$DS_CALL_LOG"
  assert_exit 0 run_gate "$@"
  assert_eq "" "$DS_STDERR"
  assert_eq "[dotsteward] this tree already passed the gate; skipped (use --force to rerun)" \
    "$(head -n 1 <<<"$DS_STDOUT")"
  assert_eq 2 "$(wc -l <<<"$DS_STDOUT")"
  memo_json=$(tail -n 1 <<<"$DS_STDOUT")
  assert_json - '(keys | sort) == (["memo", "result", "scope", "total_seconds", "tree_oid", "validated_at"])
    and .memo == true and .result == "passed"' <<<"$memo_json"
  assert_eq "" "$(fake_calls)" "a step ran on a memo answer"
  assert_call_count 0 nix '* flake *'
  assert_call_count 0 nix '* build *'
  assert_call_count 0 curl
}

memo_miss() {
  : >"$DS_CALL_LOG"
  assert_exit 0 run_gate "$@"
  assert_not_contains "$DS_STDOUT" "already passed the gate"
  assert_eq $'static\npins check --nix\nprobes' "$(fake_calls | cut -d' ' -f1-3 | sed 's/ --generation.*//')"
}

memo_miss --scope maintain
record=$(<"$gate_validation")
log_bytes=$(sha256sum <"$gate_log")

memo_hit --scope maintain
assert_eq "$(jq -c '{result, tree_oid, scope, validated_at, total_seconds, memo: true}' <<<"$record")" "$memo_json"
assert_eq "$record" "$(<"$gate_validation")" "a memo answer rewrote the record"
assert_eq "$log_bytes" "$(sha256sum <"$gate_log")" "a memo answer truncated the log"

# Scope and root are not part of the key: the recorded scope is printed.
memo_hit --scope update
assert_json - '.scope == "maintain"' <<<"$memo_json"
jq --arg r "$DS_TEST_ROOT/elsewhere" '.root = $r' "$gate_validation" >"$DS_TEST_ROOT/record"
cp "$DS_TEST_ROOT/record" "$gate_validation"
memo_hit --scope maintain

# --force reruns and records again.
memo_miss --scope maintain --force
assert_eq "$gate_inst" "$(jq -r .root "$gate_validation")"

# Another Nix version.
ds_stub_set nix version "nix (Nix) 2.99.0"
memo_miss --scope maintain
assert_eq "nix (Nix) 2.99.0" "$(jq -r .nix_version "$gate_validation")"
memo_hit --scope maintain

# Another gate version.
printf '9.8.7\n' >"$gate_fw/VERSION"
memo_miss --scope maintain
assert_eq "9.8.7" "$(jq -r .gate_version "$gate_validation")"
memo_hit --scope maintain

# A framework override, then none again.
memo_miss --scope maintain --framework-override path:/srv/dotsteward
memo_hit --scope maintain --framework-override path:/srv/dotsteward
memo_miss --scope maintain --framework-override path:/srv/other
memo_miss --scope maintain
memo_hit --scope maintain

# The denylist digest: configuring a denylist, then changing its content.
denylist=$DS_TEST_ROOT/denylist.txt
printf 'first-term\n' >"$denylist"
gate_config "[privacy]
denylist = \"$denylist\""
memo_miss --scope maintain
memo_hit --scope maintain
printf 'second-term\n' >"$denylist"
memo_miss --scope maintain
assert_eq "$(sha256sum "$denylist" | cut -d' ' -f1)" "$(jq -r .denylist_sha256 "$gate_validation")"
memo_hit --scope maintain

# A failed run keeps the previous record; going back to the passed tree is
# answered from the memo.
record=$(<"$gate_validation")
mkdir -p "$gate_inst/notes"
printf 'a\n' >"$gate_inst/notes/a.txt"
commit_all "docs: add a note"
step_fail pins 1
: >"$DS_CALL_LOG"
assert_exit 1 run_gate --scope maintain
assert_eq "$record" "$(<"$gate_validation")" "a failed run changed the record"
step_fail pins 0
git -C "$gate_inst" reset -q --hard HEAD~1
memo_hit --scope maintain

# A record of the older schema never answers.
jq '{schema_version: "1.0", result, tree_oid, base_oid, scope, nix_version, root, validated_at,
  total_seconds, step_seconds, log}' "$gate_validation" >"$DS_TEST_ROOT/record"
cp "$DS_TEST_ROOT/record" "$gate_validation"
memo_miss --scope maintain
assert_json "$gate_validation" '.schema_version == "1.1"'

# A record that did not pass never answers.
jq '.result = "failed"' "$gate_validation" >"$DS_TEST_ROOT/record"
cp "$DS_TEST_ROOT/record" "$gate_validation"
memo_miss --scope maintain

# An unreadable record is a miss, not an error.
printf 'not json\n' >"$gate_validation"
memo_miss --scope maintain
memo_hit --scope maintain
