# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# cli/dotsteward: global flags, discovery of cli/commands/<sub>.sh, help,
# unknown commands, argument and exit status passthrough.
# shellcheck source=tests/skeleton/helpers.sh
source "$DS_REPO_ROOT/tests/skeleton/helpers.sh"

real=$DS_REPO_ROOT/cli/dotsteward

# Contract for every command file in the checkout: a valid name and a
# "# summary:" line, which --help prints.
for file in "$DS_REPO_ROOT"/cli/commands/*.sh; do
  name=$(basename "$file" .sh)
  [[ $name =~ ^[a-z][a-z0-9-]*$ ]] || ds_fail "invalid command file name: $name"
  grep -q '^# summary: [^ ]' "$file" || ds_fail "$name has no '# summary:' line"
done

# The real checkout lists version with its summary.
assert_exit 0 "$real" --help
assert_contains "$DS_STDOUT" "Usage: dotsteward [--instance DIR] <command> [ARG...]"
summary=$(sed -n 's/^# summary: //p' "$DS_REPO_ROOT/cli/commands/version.sh" | head -n 1)
[[ $DS_STDOUT =~ (^|$'\n')"  version "\ +"$summary"($'\n'|$) ]] || ds_fail "version missing from help: $DS_STDOUT"
assert_exit 0 "$real" -h
assert_contains "$DS_STDOUT" "Usage: dotsteward"

# No command is a usage error.
assert_exit 1 "$real"
assert_contains "$DS_STDERR" "Usage: dotsteward"
assert_eq "" "$DS_STDOUT"

# A scratch framework copy with extra commands.
fw=$DS_TEST_ROOT/fw
copy_framework "$fw"
ds=$fw/cli/dotsteward
# shellcheck disable=SC2016 # expanded by the child shell
write_command "$fw" probe "Print arguments and environment" '
printf "arg=[%s]\n" "$@"
printf "instance=[%s]\n" "${DOTSTEWARD_INSTANCE-<unset>}"
printf "root=[%s]\n" "$DOTSTEWARD_FRAMEWORK_ROOT"
printf "lib=[%s]\n" "$DOTSTEWARD_LIB"
[[ ${1:-} != fail ]] || exit "$2"'
write_command "$fw" no-summary "" 'echo ok'
printf 'echo not a command\n' >"$fw/cli/commands/README"
printf 'echo bad name\n' >"$fw/cli/commands/Bad_Name.sh"

# Help lists only valid command files, sorted, with aligned summaries.
assert_exit 0 "$ds" --help
assert_contains "$DS_STDOUT" "Commands:
  no-summary
  probe       Print arguments and environment
  version     "
assert_not_contains "$DS_STDOUT" README
assert_not_contains "$DS_STDOUT" Bad_Name

# Arguments pass through verbatim; the exit status propagates.
assert_exit 0 "$ds" probe "two words" "" --flag '*'
assert_eq "arg=[two words]
arg=[]
arg=[--flag]
arg=[*]
instance=[<unset>]
root=[$fw]
lib=[$fw/cli/lib]" "$DS_STDOUT"
assert_exit 7 "$ds" probe fail 7
assert_exit 0 "$ds" no-summary
assert_eq ok "$DS_STDOUT"
# Options after the command belong to the command.
assert_exit 0 "$ds" probe --help
assert_contains "$DS_STDOUT" "arg=[--help]"

# Unknown commands, including anything that is not a plain command name.
for bad in nosuch Bad_Name README ../cli/dotsteward probe.sh .hidden Probe "" "-"; do
  assert_exit 1 "$ds" -- "$bad"
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: unknown command: $bad" "command [$bad]"
  assert_contains "$DS_STDERR" "available commands: no-summary probe version" "command [$bad]"
done
assert_exit 1 "$ds" nosuch
assert_eq "[dotsteward] ERROR: unknown command: nosuch
[dotsteward] available commands: no-summary probe version" "$DS_STDERR"

# Unknown global options are refused.
assert_exit 1 "$ds" --bogus probe
assert_contains "$DS_STDERR" "[dotsteward] ERROR: unknown option: --bogus"

# --instance: absolute physical path in DOTSTEWARD_INSTANCE, both spellings;
# it overrides the environment, which otherwise passes through.
mkdir -p inst/sub
ln -s inst/sub inst-link
assert_exit 0 "$ds" --instance inst/sub probe
assert_contains "$DS_STDOUT" "instance=[$PWD/inst/sub]"
assert_exit 0 "$ds" --instance=inst-link probe
assert_contains "$DS_STDOUT" "instance=[$PWD/inst/sub]"
DOTSTEWARD_INSTANCE=/from/env assert_exit 0 "$ds" probe
assert_contains "$DS_STDOUT" "instance=[/from/env]"
DOTSTEWARD_INSTANCE=/from/env assert_exit 0 "$ds" --instance inst probe
assert_contains "$DS_STDOUT" "instance=[$PWD/inst]"
assert_exit 1 "$ds" --instance missing probe
assert_contains "$DS_STDERR" "[dotsteward] ERROR: --instance: not a directory: missing"
assert_exit 1 "$ds" --instance
assert_contains "$DS_STDERR" "[dotsteward] ERROR: --instance requires a directory"
assert_exit 1 "$ds" --instance=
assert_contains "$DS_STDERR" "[dotsteward] ERROR: --instance requires a directory"

# The dispatcher works through a symlink and from any working directory.
mkdir -p bin
ln -s "$ds" bin/dotsteward
assert_exit 0 bin/dotsteward probe
assert_contains "$DS_STDOUT" "root=[$fw]"
# shellcheck disable=SC2016 # expanded by the child shell
assert_exit 0 bash -c 'cd / && "$1" probe' bash "$PWD/bin/dotsteward"
assert_contains "$DS_STDOUT" "root=[$fw]"

# Commands run with the dispatcher's bash, so they need no executable bit.
chmod 0644 "$fw/cli/commands/no-summary.sh"
assert_exit 0 "$ds" no-summary
assert_eq ok "$DS_STDOUT"
