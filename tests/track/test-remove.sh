# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# `dotsteward remove NAME` stops tracking a component in one maintain transaction: its table, its
# entry of [components] order and, for a component of the instance, components/NAME go, under the
# subject "feat: stop tracking NAME", through the one dotsteward apply. The software stays: no
# package is removed and no file of the machine is deleted. Only --uninstall removes what the
# component installed outside the Home Manager profile, after the commit landed: the APT packages
# no other component names (on a terminal through sudo, else uninstall-required with the command,
# exit 3), and an official binary with its companions. A component that another one requires
# stays, and so does a name that is not tracked (exit 0, nothing to do).
# shellcheck source=tests/track/helpers.sh
source "$DS_REPO_ROOT/tests/track/helpers.sh"

ds_dpkg_installed example-tracked 1.0-1
ds_dpkg_installed example-tracked-lib 1.0-1

# Stop tracking a deb component: the packages stay installed.
set_toml components order '["example-app", "codex"]'
git -C "$up_inst" commit -q -am "chore: an order"
git -C "$up_inst" push -q origin HEAD:main
base=$(remote_oid)
clear_log
assert_exit 0 remove example-app --activate --publish
assert_eq "feat: stop tracking example-app" "$(git -C "$up_inst" log -1 --format=%s)"
assert_eq "$base" "$(git -C "$up_inst" rev-parse HEAD^)" "one commit"
assert_eq "$(head_oid)" "$(remote_oid)" "published"
toml_at HEAD '.components["example-app"] == null and .components.order == ["codex"]'
toml_at HEAD '.components.codex.enable == true'
assert_order '^static ' '^rebuild ' '^e2e '
assert_no_step '^sudo '
assert_no_step 'apt-get'
assert_contains "$DS_STDOUT" "stays installed"
assert_contains "$DS_STDOUT" "example-tracked"

# Not tracked any more: nothing to do.
clear_log
assert_exit 0 remove example-app --publish
assert_contains "$DS_STDOUT" "example-app is not tracked"
assert_no_step '^static '

# A component another one requires stays.
component_entry example-base '{"method": "nix"}'
component_entry example-plugin '{"method": "nix", "requires": ["example-base"]}'
enable_component example-base
enable_component example-plugin
head=$(head_oid)
assert_exit 1 remove example-base --publish
assert_contains "$DS_STDERR" "example-plugin"
assert_eq "$head" "$(head_oid)" "no commit"
assert_eq "" "$(git -C "$up_inst" status --porcelain)" "nothing written"

# A component of the instance goes with its directory; a nix component leaves the profile at the
# next activation, which the summary says.
mkdir -p "$up_inst/components/example-plugin"
printf '{ ... }:\n{\n  dotsteward.components.example-plugin = { };\n}\n' >"$up_inst/components/example-plugin/default.nix"
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "feat: the definition of example-plugin"
git -C "$up_inst" push -q origin HEAD:main
assert_exit 0 remove example-plugin --publish --json
assert_stdout_json '.command == "remove" and .component == "example-plugin" and .change == "removed"'
assert_stdout_json '.apply.status == "ok" and .exit_code == 0 and .uninstall == null'
[[ ! -e $up_inst/components/example-plugin ]] || ds_fail "the directory of the component is still there"
assert_eq "" "$(git -C "$up_inst" ls-tree HEAD components/example-plugin)" "the directory left the tree"
assert_contains "$DS_STDERR" "next activation"

# --uninstall of a deb component without a terminal: the commit lands, the command waits for the
# person (exit 3); packages another component names stay out of it.
component_entry example-other '{"method": "deb", "install": {"apt": ["example-shared"]}}'
component_entry example-player '{"method": "deb", "install": {"packageNames": ["example-player"], "apt": ["example-shared"]}}'
enable_component example-other
enable_component example-player
ds_dpkg_installed example-player 2.0-1
ds_dpkg_installed example-shared 2.0-1
clear_log
assert_exit 3 remove example-player --uninstall --publish --json
assert_eq "$(head_oid)" "$(remote_oid)" "the commit is published first"
assert_stdout_json '.uninstall.status == "pending" and .uninstall.run == "sudo apt-get remove example-player"'
assert_stdout_json '[.ask[].code] == ["uninstall-required"]'
assert_no_step '^sudo '
# On a terminal the same command runs it: the commit is published already.
clear_log
assert_exit 0 on_terminal_run -- remove example-player --uninstall --publish
assert_order '^sudo apt-get remove example-player$'
assert_no_step '^static '

# --uninstall of an official binary deletes it and its companions; without --uninstall it stays.
mkdir -p "$HOME/.local/bin"
printf 'binary\n' >"$HOME/.local/bin/codex"
printf 'helper\n' >"$HOME/.local/bin/codex-helper"
assert_exit 0 remove codex --uninstall --publish
[[ ! -e $HOME/.local/bin/codex && ! -e $HOME/.local/bin/codex-helper ]] || ds_fail "the binary is still there"
toml_at HEAD '.components.codex == null'
printf 'binary\n' >"$HOME/.local/bin/claude"
assert_exit 0 remove claude-code --publish
[[ -e $HOME/.local/bin/claude ]] || ds_fail "remove deleted a binary without --uninstall"
