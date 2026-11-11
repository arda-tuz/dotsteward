# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# remove never deletes what it cannot prove is the component's:
# - in components/NAME only the files git has committed go; an ignored file stays and is named; a
#   file git does not know, or one only staged by an add that did not finish, is a question
#   (untracked-files), and nothing is written;
# - --uninstall deletes a path only when it is strictly below HOME and is what the component
#   installed: a link of a Python application into its own environment, an environment with its
#   pyvenv.cfg, a binary that answers the version probe of the component; and only once the
#   removal is published;
# - a nix component would leave the profile of every machine it is for: a plain remove asks
#   (profile-removal), --uninstall confirms, --keep-here keeps it on this machine only;
# - what this machine said about the component goes with it: its host file's declined entry and
#   holds (its name, as earlier releases wrote it, `component:` and the `pin:` holds of its pins;
#   those of other components stay), the pin holds of this machine; the pins of the component are
#   named;
# - the requires check runs on the tree begin brought, so a dependent another machine just
#   published stops it.
# shellcheck source=tests/track/helpers.sh
source "$DS_REPO_ROOT/tests/track/helpers.sh"

# --- the directory of the component -----------------------------------------------------------
mkdir -p "$up_inst/components/example-notes"
printf '{ ... }:\n{\n  dotsteward.components.example-notes = { };\n}\n' >"$up_inst/components/example-notes/default.nix"
printf 'components/example-notes/*.local\n' >>"$up_inst/.gitignore"
component_entry example-notes '{"method": "deb", "install": {"apt": ["example-notes"]}}'
enable_component example-notes
printf 'my notes, not in git\n' >"$up_inst/components/example-notes/notes.local"
printf '# a second module the agent is writing\n' >"$up_inst/components/example-notes/extra.nix"
head=$(head_oid)
assert_exit 3 remove example-notes --publish --json
assert_stdout_json '[.ask[].code] == ["untracked-files"] and .ask[0].paths == ["components/example-notes/extra.nix"]'
assert_eq "$head" "$(head_oid)" "no commit"
[[ -f $up_inst/components/example-notes/extra.nix && -f $up_inst/components/example-notes/default.nix ]] ||
  ds_fail "remove deleted a file while it asked"
rm -f -- "$up_inst/components/example-notes/extra.nix"
assert_exit 0 remove example-notes --publish
assert_contains "$DS_STDOUT" "components/example-notes/notes.local stays"
[[ -f $up_inst/components/example-notes/notes.local ]] || ds_fail "remove deleted an ignored file"
assert_eq "" "$(git -C "$up_inst" ls-tree HEAD components/example-notes)" "the committed files left the tree"

# A directory an add left after a red gate: nothing of it is committed, nothing goes.
touch "$UP_CONTROL/static-red"
assert_exit 1 add example-draft --nix hello
rm -f -- "$UP_CONTROL/static-red"
printf 'the notes of the agent\n' >"$up_inst/components/example-draft/NOTES.txt"
assert_exit 0 remove example-draft --publish
[[ -f $up_inst/components/example-draft/NOTES.txt && -f $up_inst/components/example-draft/default.nix ]] ||
  ds_fail "remove deleted the directory of an add that did not finish"
assert_contains "$DS_STDOUT" "example-draft is not tracked"
git -C "$up_inst" reset -q --hard
git -C "$up_inst" clean -qfd -- components/example-draft

# --- --uninstall: only what the component installed, only once published ----------------------
component_entry example-py '{"method": "pypi", "install": {"venv": "~/.local/share/example-py/venv", "bin": ["example-py", "example-py-tool"]}}'
enable_component example-py
venv=$HOME/.local/share/example-py/venv
mkdir -p "$HOME/.local/bin" "$venv/bin"
printf 'home = /usr/bin\n' >"$venv/pyvenv.cfg"
printf '#!/bin/sh\n' >"$venv/bin/example-py-tool"
ln -s "$venv/bin/example-py-tool" "$HOME/.local/bin/example-py-tool"
printf '#!/bin/sh\necho my own wrapper\n' >"$HOME/.local/bin/example-py"
assert_exit 0 remove example-py --uninstall --no-publish
assert_contains "$DS_STDOUT" "not published"
[[ -d $venv && -L $HOME/.local/bin/example-py-tool ]] || ds_fail "--uninstall deleted before the removal was published"
assert_exit 0 remove example-py --uninstall --publish
[[ ! -e $venv && ! -L $HOME/.local/bin/example-py-tool ]] || ds_fail "the environment and its link are still there"
[[ -f $HOME/.local/bin/example-py ]] || ds_fail "--uninstall deleted the person's own script of the same name"
assert_contains "$DS_STDOUT" "$HOME/.local/bin/example-py stays"

# A path outside HOME, or HOME itself, is never deleted.
component_entry example-wide '{"method": "pypi", "install": {"venv": "~/../outside-venv", "bin": []}}'
enable_component example-wide
mkdir -p "$HOME/../outside-venv"
printf 'home = /usr/bin\n' >"$HOME/../outside-venv/pyvenv.cfg"
assert_exit 0 remove example-wide --uninstall --publish
[[ -d $HOME/../outside-venv ]] || ds_fail "--uninstall deleted a directory outside HOME"

# An official binary goes only when it answers the version probe of the component.
component_entry example-bin '{"method": "official-binary", "install": {"dest": "~/.local/bin/example-bin",
  "versionArgv": ["--version"], "versionRegex": "example-bin ([0-9.]+)", "companions": [{"file": "example-bin-helper"}]}}'
enable_component example-bin
printf '#!/bin/sh\necho something else 1.0\n' >"$HOME/.local/bin/example-bin"
chmod 0755 "$HOME/.local/bin/example-bin"
printf 'helper\n' >"$HOME/.local/bin/example-bin-helper"
assert_exit 0 remove example-bin --uninstall --publish
[[ -f $HOME/.local/bin/example-bin && -f $HOME/.local/bin/example-bin-helper ]] ||
  ds_fail "--uninstall deleted a binary that is not the component's"
assert_contains "$DS_STDOUT" "$HOME/.local/bin/example-bin stays"

# --- a nix component -------------------------------------------------------------------------
mkdir -p "$up_inst/hosts"
for host in example-host other-host; do
  printf 'schema_version = 1\nsystem = "%s"\nprofile = "workstation"\nplatform = "ubuntu-24.04"\n' "$system" \
    >"$up_inst/hosts/$host.toml"
done
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "chore: another machine"
git -C "$up_inst" push -q origin HEAD:main
component_entry example-tool '{"method": "nix", "install": {"packages": ["example-tool"]}}'
enable_component example-tool
head=$(head_oid)
assert_exit 3 remove example-tool --publish --json
assert_stdout_json '[.ask[].code] == ["profile-removal"] and (.ask[0].machines | index("other-host") != null)'
assert_stdout_json '.ask[0].message | test("--uninstall") and test("--keep-here")'
assert_eq "$head" "$(head_oid)" "no commit"
assert_exit 0 remove example-tool --keep-here --publish
toml_at HEAD '.components["example-tool"] == {enable: true, machines: ["example-host"]}'
assert_eq "feat: keep example-tool on example-host only" "$(git -C "$up_inst" log -1 --format=%s)"
assert_exit 0 remove example-tool --uninstall --publish
toml_at HEAD '.components["example-tool"] == null'

# --- what this machine said about it ---------------------------------------------------------
component_entry example-held '{"method": "deb", "install": {"apt": ["example-held"], "pin": "desktop_packages.example-held"}}'
enable_component example-held
printf 'schema_version = 1\nsystem = "%s"\nprofile = "workstation"\nplatform = "ubuntu-24.04"\n\n[declined]\ncomponents = ["example-held", "example-other"]\n\n[holds.example-held]\nversion = "1.0"\nreason = "a regression"\n\n[holds."component:example-held"]\nversion = "1.0"\nreason = "a regression"\n\n[holds."pin:desktop_packages.example-held"]\nversion = "1.0"\nreason = "e2e-red"\n\n[holds."component:example-other"]\nversion = "3"\nreason = "another component"\n' \
  "$system" >"$up_inst/hosts/example-host.toml"
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "chore: this machine declined example-held"
git -C "$up_inst" push -q origin HEAD:main
jq -n '{schema_version: 1, holds: [{component: "example-held", id: "desktop_packages.example-held", version: "1.0",
  reason: "e2e-red", since: "2026-11-01T00:00:00Z"}, {component: "codex", id: "agent_tools.codex.linux", version: "9",
  reason: "e2e-red", since: "2026-11-01T00:00:00Z"}]}' >"$DOTSTEWARD_STATE_ROOT/holds.json"
assert_exit 0 remove example-held --publish
host=$(git -C "$up_inst" show HEAD:hosts/example-host.toml)
assert_not_contains "$host" "example-held"
assert_contains "$host" '"example-other"'
assert_contains "$host" '[holds."component:example-other"]'
assert_json "$DOTSTEWARD_STATE_ROOT/holds.json" '[.holds[].component] == ["codex"]'
assert_contains "$DS_STDOUT" "desktop_packages.example-held"

# --- requires on the tree begin brought --------------------------------------------------------
component_entry example-base '{"method": "deb", "install": {"apt": ["example-base"]}}'
enable_component example-base
other=$DS_TEST_ROOT/other-clone
git clone -q "$up_bare" "$other"
other_mirror=$other/.dotsteward/$(basename "$mirror")
jq '.components += [{name: "example-plugin", method: "deb", profiles: null, platforms: ["linux"], install: {},
  requires: ["example-base"]}]' "$other_mirror" >"$other_mirror.new"
mv -- "$other_mirror.new" "$other_mirror"
printf '\n[components.example-plugin]\nenable = true\n' >>"$other/workstation.toml"
git -C "$other" add -A
git -C "$other" -c user.name=other -c user.email=other@example.invalid commit -q -m "feat: track example-plugin"
git -C "$other" push -q origin HEAD:main
assert_exit 1 remove example-base --publish
assert_contains "$DS_STDERR" "example-plugin requires example-base"
git -C "$up_inst" show origin/main:workstation.toml | grep -q 'components.example-base' ||
  ds_fail "example-base left the remote although example-plugin requires it"
