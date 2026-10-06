# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# [skills] installer (SPEC D2, 4.1): an argv template replaces the native
# copy for copy-deployed skills that are missing; {source} (the vendored
# directory), {name} (the lock name) and {home} are substituted in every
# argument; it runs with an empty standard input, and the skill must be
# found afterwards (and match the lock digest). A failing installer or one
# that installs nothing is fatal.
# shellcheck source=tests/agents/helpers.sh
source "$DS_REPO_ROOT/tests/agents/helpers.sh"

installer=$DS_TEST_ROOT/bin/example-installer
mkdir -p "${installer%/*}"
cat >"$installer" <<EOF
#!$BASH
set -eu
printf '%s\n' "\$*" >>$(printf %q "$DS_TEST_ROOT/installer.log")
if [[ -t 0 ]] || read -r -t 0.1 _; then
  echo "stdin is not empty" >&2
  exit 9
fi
case \${EXAMPLE_INSTALLER_MODE:-copy} in
  copy) cp -a "\$2" "\$4/.agents/skills/\$3" ;;
  nothing) ;;
  fail) exit 5 ;;
esac
EOF
chmod 0755 "$installer"
set_installer "[\"$installer\", \"add\", \"{source}\", \"{name}\", \"{home}\", \"--name={name}\"]"
lock_add alpha

assert_exit 0 run_agents install
assert_eq "$(cat "$DS_TEST_ROOT/installer.log")" "add $(vendored alpha) alpha $HOME --name=alpha"
assert_contains "$DS_STDOUT" "installed skill alpha into $HOME/.agents/skills/alpha"
assert_symlink_to "$HOME/.claude/skills/alpha" ../../.agents/skills/alpha
assert_exit 0 run_agents check
# Present skills never call the installer.
assert_exit 0 run_agents install
assert_eq "$(wc -l <"$DS_TEST_ROOT/installer.log")" 1

rm -rf "$HOME/.agents/skills/alpha"
export EXAMPLE_INSTALLER_MODE=nothing
assert_exit 1 run_agents install
assert_contains "$DS_STDERR" "skill install could not be verified: alpha"

export EXAMPLE_INSTALLER_MODE=fail
assert_exit 1 run_agents install
assert_contains "$DS_STDERR" "skill installer failed: alpha (exit 5)"

# An installer that is not executable.
set_installer "[\"$DS_TEST_ROOT/bin/missing-installer\", \"{source}\"]"
assert_exit 1 run_agents install
assert_contains "$DS_STDERR" "skill installer not found: $DS_TEST_ROOT/bin/missing-installer"

# A dangling managed link at the destination (the legacy copy it pointed to
# is gone) is removed before the installer runs, so the installer never
# writes through it into the legacy root.
set_installer "[\"$installer\", \"add\", \"{source}\", \"{name}\", \"{home}\", \"--name={name}\"]"
export EXAMPLE_INSTALLER_MODE=copy
mkdir -p "$HOME/.codex/skills"
ln -s ../../.codex/skills/alpha "$HOME/.agents/skills/alpha"
assert_exit 0 run_agents install
assert_contains "$DS_STDOUT" "removed dangling skill link: $HOME/.agents/skills/alpha"
[[ -d $HOME/.agents/skills/alpha && ! -L $HOME/.agents/skills/alpha ]] || ds_fail "the installer writes a physical copy"
[[ ! -e $HOME/.codex/skills/alpha ]] || ds_fail "nothing is written through the dangling link"
assert_exit 0 run_agents check
