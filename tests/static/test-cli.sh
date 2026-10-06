# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# `dotsteward static` command line: help, options, usage errors and target
# discovery (instance from --instance, DOTSTEWARD_INSTANCE or the working
# directory; framework source; neither).
# shellcheck source=tests/static/helpers.sh
source "$DS_REPO_ROOT/tests/static/helpers.sh"

assert_exit 0 "$DS_CLI" --help
[[ $DS_STDOUT =~ (^|$'\n')"  static "\ +[A-Z] ]] || ds_fail "static missing from help: $DS_STDOUT"

assert_exit 0 static --help
assert_contains "$DS_STDOUT" "Usage: dotsteward [--instance DIR] static [--sandbox] [--only CHECK]..."
for word in --sandbox --only launcher bootstrap skills versions-lock allowlist protected overlays \
  shell bans privacy scripts command-names seeds; do
  assert_contains "$DS_STDOUT" "$word"
done

assert_exit 1 static --bogus
assert_contains "$DS_STDERR" "[dotsteward] ERROR: unknown option: --bogus"
assert_exit 1 static extra
assert_contains "$DS_STDERR" "[dotsteward] ERROR: unexpected argument: extra"
assert_exit 1 static --only
assert_contains "$DS_STDERR" "--only requires a value"

# Neither an instance nor the framework source: the instance discovery error.
mkdir elsewhere
cd elsewhere
assert_exit 1 static
assert_contains "$DS_STDERR" "[dotsteward] ERROR:"
assert_contains "$DS_STDERR" "workstation.toml"

make_instance "$DS_TEST_ROOT/inst"

# Unknown checks are refused before anything runs; framework-only checks do
# not exist for an instance.
cd "$DS_TEST_ROOT/inst"
assert_exit 1 static --only nonsense
assert_contains "$DS_STDERR" "[dotsteward] ERROR: unknown check for an instance: nonsense"
assert_exit 1 static --only seeds
assert_contains "$DS_STDERR" "unknown check for an instance: seeds"

# Discovery: the working directory (also a subdirectory), --instance and
# DOTSTEWARD_INSTANCE.
assert_exit 0 static --only launcher
assert_contains "$DS_STDOUT" "[dotsteward] static checks passed (instance): launcher"
cd scripts
assert_exit 0 static --only launcher,protected
assert_contains "$DS_STDOUT" "[dotsteward] static checks passed (instance): launcher protected"
cd "$DS_TEST_ROOT/work/elsewhere"
assert_exit 0 "$DS_CLI" --instance "$DS_TEST_ROOT/inst" static --only launcher --only versions-lock
assert_contains "$DS_STDOUT" "[dotsteward] static checks passed (instance): launcher versions-lock"
assert_exit 0 env DOTSTEWARD_INSTANCE="$DS_TEST_ROOT/inst" "$DS_CLI" static --only launcher
assert_contains "$DS_STDOUT" "static checks passed (instance)"

# The framework source: framework mode, with its own check names.
cd "$DS_REPO_ROOT"
assert_exit 1 static --only launcher
assert_contains "$DS_STDERR" "[dotsteward] ERROR: unknown check for the framework: launcher"
assert_exit 0 static --sandbox --only seeds
assert_contains "$DS_STDOUT" "[dotsteward] static checks passed (framework): seeds"
