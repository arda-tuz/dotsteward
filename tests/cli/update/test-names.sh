# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # the stand-ins are written with their literal $(...)
# shellcheck disable=SC2030,SC2031 # ds_record_line writes one line to a log of its own
# The command names: `generate` writes the mirrors and `txn` runs the steps of a
# transaction, while `sync` and `update` stay through 1.x as their old names:
# one warning line on standard error, then the new command with the same
# arguments, the same standard output and the same exit status, so a script that
# parses the output or tests the status of the old name keeps working.
# shellcheck source=tests/cli/update/helpers.sh
source "$DS_REPO_ROOT/tests/cli/update/helpers.sh"

fw=$DS_TEST_ROOT/framework
mkdir -p "$fw"
cp -R "$DS_REPO_ROOT/cli" "$DS_REPO_ROOT/schema" "$DS_REPO_ROOT/VERSION" "$fw/"

# In this copy generate and txn only record their arguments, print one line and
# exit with the status in DS_TEST_ROOT/exit-status.
for command in generate txn; do
  {
    printf '#!%s\n' "$BASH"
    printf '# summary: stand-in of %s\n' "$command"
    printf 'source %q\n' "$DS_REPO_ROOT/tests/lib/harness.sh"
    printf 'ds_record_call %s "$@"\n' "$command"
    printf 'printf "standard output of %s\\n"\n' "$command"
    printf 'exit "$(<%q)"\n' "$DS_TEST_ROOT/exit-status"
  } >"$fw/cli/commands/$command.sh"
done

warning_of() {
  printf "[dotsteward] WARNING: 'dotsteward %s' is the old name of 'dotsteward %s'; the old name stops working in 2.0.0" "$1" "$2"
}

# alias_passes_through OLD NEW STATUS ARG...: OLD ARG... ran NEW ARG... once with
# the arguments word for word, printed what NEW printed and exited with STATUS.
alias_passes_through() {
  local old=$1 new=$2 status=$3
  shift 3
  : >"$DS_CALL_LOG"
  printf '%s\n' "$status" >"$DS_TEST_ROOT/exit-status"
  assert_exit "$status" "$fw/cli/dotsteward" --instance "$up_inst" "$old" "$@" </dev/null
  assert_eq "standard output of $new" "$DS_STDOUT"
  assert_eq "$(warning_of "$old" "$new")" "$DS_STDERR"
  assert_calls "$(ds_record_line "$new" "$@")"
}

# ds_record_line NAME ARG...: the line ds_record_call writes for NAME ARG....
ds_record_line() {
  (
    export DS_CALL_LOG=$DS_TEST_ROOT/one-line.log
    : >"$DS_CALL_LOG"
    ds_record_call "$@"
    cat -- "$DS_CALL_LOG"
  )
}

for status in 0 1 2 3 7; do
  alias_passes_through sync generate "$status" --nix --skill "two words"
  alias_passes_through update txn "$status" publish --scope maintain --expected-base 0123abc
done
alias_passes_through sync generate 0
alias_passes_through update txn 0 status --json
alias_passes_through update txn 0 prepare --official-sources-only --scope=maintain

# Without an instance too: the old name asks for nothing itself.
: >"$DS_CALL_LOG"
printf '0\n' >"$DS_TEST_ROOT/exit-status"
assert_exit 0 "$fw/cli/dotsteward" sync --help </dev/null
assert_calls "$(ds_record_line generate --help)"

# The real commands: the new names do not warn, the old names do, and the JSON on
# standard output of the old name is the document of the new name.
assert_exit 0 "$DS_REPO_ROOT/cli/dotsteward" --instance "$up_inst" txn status --json </dev/null
assert_eq "" "$DS_STDERR"
new_document=$DS_STDOUT
assert_exit 0 "$DS_REPO_ROOT/cli/dotsteward" --instance "$up_inst" update status --json </dev/null
assert_eq "$(warning_of update txn)" "$DS_STDERR"
assert_eq "$new_document" "$DS_STDOUT"
assert_json - '.schema_version == 1 and has("candidate")' <<<"$DS_STDOUT"

# A refusal keeps its status and its message behind the warning.
assert_exit 1 "$DS_REPO_ROOT/cli/dotsteward" --instance "$up_inst" txn bogus </dev/null
refusal=$DS_STDERR
assert_contains "$refusal" "bogus"
assert_exit 1 "$DS_REPO_ROOT/cli/dotsteward" --instance "$up_inst" update bogus </dev/null
assert_eq "$(warning_of update txn)"$'\n'"$refusal" "$DS_STDERR"
assert_eq "" "$DS_STDOUT"

# The help of each name says what the command takes.
assert_exit 0 "$DS_REPO_ROOT/cli/dotsteward" generate --help </dev/null
assert_contains "$DS_STDOUT" "Usage: dotsteward generate"
assert_contains "$DS_STDOUT" "--nix"
assert_eq "" "$DS_STDERR"
assert_exit 0 "$DS_REPO_ROOT/cli/dotsteward" txn --help </dev/null
assert_contains "$DS_STDOUT" "Usage: dotsteward [--instance DIR] txn prepare --official-sources-only"
assert_eq "" "$DS_STDERR"
assert_exit 0 "$DS_REPO_ROOT/cli/dotsteward" sync --help </dev/null
assert_contains "$DS_STDOUT" "Usage: dotsteward generate"
assert_eq "$(warning_of sync generate)" "$DS_STDERR"
assert_exit 0 "$DS_REPO_ROOT/cli/dotsteward" update --help </dev/null
assert_contains "$DS_STDOUT" "Usage: dotsteward [--instance DIR] txn prepare --official-sources-only"
assert_eq "$(warning_of update txn)" "$DS_STDERR"

# The dispatcher lists all four, and each old name says which name took over.
assert_exit 0 "$DS_REPO_ROOT/cli/dotsteward" --help </dev/null
assert_contains "$(grep -E '^  generate ' <<<"$DS_STDOUT")" "mirrors"
assert_contains "$(grep -E '^  txn ' <<<"$DS_STDOUT")" "maintenance transaction"
assert_contains "$(grep -E '^  sync ' <<<"$DS_STDOUT")" "Old name of generate"
assert_contains "$(grep -E '^  update ' <<<"$DS_STDOUT")" "Old name of txn"
