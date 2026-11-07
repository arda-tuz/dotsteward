# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# E35: CLI N and a tree of N+1 with a key N does not know. upgrade looks at the revisions before it
# reads the configuration and goes on with the CLI the tree pins, once, with the arguments it got;
# a pull that brings a newer pin does the same with the chosen mode. Development CLIs stay.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

running=1111111111111111111111111111111111111111
pinned=2222222222222222222222222222222222222222

pin_framework() {
  jq -n --arg rev "$1" '{
    nodes: {
      root: {inputs: {dotsteward: "dotsteward_2"}},
      dotsteward_2: {locked: {type: "github", rev: $rev}}
    },
    root: "root", version: 7
  }' >"$up_inst/flake.lock"
}

printf 'rev=%s\nnarHash=sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n' "$running" >"$fw/source-info"

# What the launcher starts: it just says what it got.
cat >"$up_inst/.dotsteward/cli.sh" <<LAUNCHER
#!$BASH
printf 'pinned-cli %s reexec=%s\n' "\$*" "\${DOTSTEWARD_UPGRADE_REEXEC:-}" >>"$UP_LOG"
# The lock of the run before does not come along: this process can take it itself.
PYTHONPATH="$DS_REPO_ROOT/cli/python" PYTHONDONTWRITEBYTECODE=1 python3 -s -P -m dotsteward_cli.internal \
  lock run --holder probe --state-root "$DOTSTEWARD_STATE_ROOT" -- true || exit 97
exit 42
LAUNCHER
chmod 0755 "$up_inst/.dotsteward/cli.sh"

# The tree is newer than this CLI: the configuration of N+1 does not stop it.
pin_framework "$pinned"
printf '\n[a_later_table]\nkey = 1\n' >>"$up_inst/workstation.toml"
assert_exit 42 upgrade --tracked --accept install:example-a
assert_eq "pinned-cli upgrade --tracked --accept install:example-a reexec=1" "$(steps '^pinned-cli')"

# Without the way out, the message of the configuration names the same command.
clear_log
DOTSTEWARD_UPGRADE_REEXEC=1 assert_exit 1 upgrade --tracked
assert_contains "$DS_STDERR" "unknown key a_later_table"
assert_contains "$DS_STDERR" "$up_inst/.dotsteward/cli.sh"
assert_eq "" "$(steps '^pinned-cli')"

# A development CLI stays what it is, whatever the pin says.
git -C "$up_inst" checkout -q -- workstation.toml
tool_stub claude
tool_stub fwupdmgr 'exit 2'
clear_log
DOTSTEWARD_FRAMEWORK_OVERRIDE=/some/where assert_exit 0 upgrade --plan --json
assert_eq "" "$(steps "^pinned-cli")"
rm -f -- "$fw/source-info"
pin_framework "$pinned"
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "chore: pin"
git -C "$up_inst" push -q origin HEAD:main
clear_log
assert_exit 3 upgrade --tracked
assert_eq "" "$(steps '^pinned-cli')" "without source-info nothing is compared"

# A pull brings a pin this CLI is not: the run goes on there, with the mode chosen on the menu.
printf 'rev=%s\nnarHash=sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n' "$pinned" >"$fw/source-info"
clone=$DS_TEST_ROOT/other-clone
git clone -q "$up_bare" "$clone"
jq -n --arg rev "3333333333333333333333333333333333333333" '{
  nodes: {root: {inputs: {dotsteward: "dotsteward_2"}}, dotsteward_2: {locked: {type: "github", rev: $rev}}},
  root: "root", version: 7
}' >"$clone/flake.lock"
git -C "$clone" add -A
git -C "$clone" commit -q -m "chore: move the framework"
git -C "$clone" push -q origin HEAD:main
clear_log
assert_exit 42 on_terminal 'Update what=1' --
assert_eq "pinned-cli upgrade --tracked reexec=1" "$(steps '^pinned-cli')"
assert_no_step '^(sudo|apt commit|pins|rebuild|e2e)'
