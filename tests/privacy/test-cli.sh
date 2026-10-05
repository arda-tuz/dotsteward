# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# `dotsteward scan` command line: help, mode selection, usage errors, and a
# direct run of cli/commands/scan.sh without the dispatcher (the pre-push
# hook calls it that way).
# shellcheck source=tests/privacy/helpers.sh
source "$DS_REPO_ROOT/tests/privacy/helpers.sh"

# The dispatcher lists the command with its summary.
assert_exit 0 "$DS_CLI" --help
[[ $DS_STDOUT =~ (^|$'\n')"  scan "\ +[A-Z] ]] || ds_fail "scan missing from help: $DS_STDOUT"

assert_exit 0 scan --help
assert_contains "$DS_STDOUT" "Usage: dotsteward scan (--tree | --staged | --range RANGE) [OPTION...]"
for flag in --tree --staged --range --denylist --require-denylist --metadata --extra-terms --redact; do
  assert_contains "$DS_STDOUT" "$flag"
done
assert_exit 0 scan -h
assert_contains "$DS_STDOUT" "Usage: dotsteward scan"

mkdir plain
cd plain
printf 'hello\n' >readme.txt

# Exactly one mode.
assert_exit 1 scan
assert_contains "$DS_STDERR" "[dotsteward] ERROR: choose exactly one of --tree, --staged or --range"
assert_exit 1 scan --tree --staged
assert_contains "$DS_STDERR" "choose exactly one of --tree, --staged or --range"
assert_exit 1 scan --tree --range HEAD
assert_contains "$DS_STDERR" "choose exactly one of --tree, --staged or --range"
assert_exit 1 scan --range HEAD --range HEAD
assert_contains "$DS_STDERR" "choose exactly one of --tree, --staged or --range"

# Unknown options and missing values.
assert_exit 1 scan --tree --bogus
assert_contains "$DS_STDERR" "[dotsteward] ERROR: unknown option: --bogus"
assert_exit 1 scan --tree extra
assert_contains "$DS_STDERR" "unexpected argument: extra"
for flag in --range --denylist --extra-terms; do
  assert_exit 1 scan "$flag"
  assert_contains "$DS_STDERR" "$flag requires a value"
done
assert_exit 1 scan --range ""
assert_contains "$DS_STDERR" "--range requires a value"

# --metadata only applies to commits.
assert_exit 1 scan --tree --metadata
assert_contains "$DS_STDERR" "--metadata requires --range"

# Term files must exist; their paths are echoed as given, never their content.
assert_exit 1 scan --tree --denylist missing.txt
assert_contains "$DS_STDERR" "[dotsteward] ERROR: denylist file is missing or unreadable: missing.txt"
assert_exit 1 scan --tree --extra-terms missing.txt
assert_contains "$DS_STDERR" "[dotsteward] ERROR: extra-terms file is missing or unreadable: missing.txt"
mkdir a-directory
assert_exit 1 scan --tree --denylist a-directory
assert_contains "$DS_STDERR" "denylist file is missing or unreadable: a-directory"

# --staged and --range need git.
assert_exit 1 scan --staged
assert_contains "$DS_STDERR" "[dotsteward] ERROR: --staged requires a git work tree"
assert_exit 1 scan --range HEAD
assert_contains "$DS_STDERR" "[dotsteward] ERROR: --range requires a git repository"

# Range revisions never pass through as git options.
cd "$DS_TEST_ROOT/work"
use_noreply_identity
new_repo repo
cd repo
printf 'hello\n' >readme.txt
commit_all . "docs: add readme"
for range in --all "-n1" "HEAD --all" "HEAD..HEAD -p"; do
  assert_exit 1 scan --range "$range"
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: invalid range: $range"
done
assert_exit 1 scan --range no-such-rev..HEAD
assert_contains "$DS_STDERR" "[dotsteward] ERROR: invalid range: no-such-rev..HEAD"

# Clean runs, through the dispatcher and directly.
assert_exit 0 scan --tree
assert_eq "[dotsteward] scan clean: 1 files, 0 commits" "$DS_STDOUT"
assert_eq "" "$DS_STDERR"
assert_exit 0 "$DS_REPO_ROOT/cli/commands/scan.sh" --tree --redact
assert_eq "[dotsteward] scan clean: 1 files, 0 commits" "$DS_STDOUT"
assert_exit 0 env -i PATH="$PATH" HOME="$HOME" bash "$DS_REPO_ROOT/cli/commands/scan.sh" --range HEAD --metadata --redact
assert_eq "[dotsteward] scan clean: 1 files, 1 commits" "$DS_STDOUT"
assert_exit 0 scan --staged
assert_eq "[dotsteward] scan clean: 0 files, 0 commits" "$DS_STDOUT"
assert_exit 0 scan --range=HEAD..HEAD
assert_eq "[dotsteward] scan clean: 0 files, 0 commits" "$DS_STDOUT"

# The library parses as a sourced file and the command is executable.
[[ -x $DS_REPO_ROOT/cli/commands/scan.sh ]] || ds_fail "scan.sh is not executable"
bash -n "$DS_REPO_ROOT/cli/lib/privacy.sh"
