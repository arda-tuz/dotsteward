# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# - remove deletes nothing in components/NAME that differs from HEAD: an uncommitted edit of a
#   committed file, staged or not, is a question (untracked-files) and nothing is written;
# - a table without a scope key is for every machine: --here or --tags that would leave machines
#   out stops with scope-narrowed, naming them; for a nix component profile-removal too;
#   --replace-scope confirms;
# - remove --keep-here keeps a component only where it applies on this machine: elsewhere (its
#   machines, its tags, an answer Never) it refuses and says why and what to run; when it keeps it,
#   it names the machines that lose it; this machine needs its host file;
# - a component that does not apply here because of its tags names the way on.
# shellcheck source=tests/track/helpers.sh
source "$DS_REPO_ROOT/tests/track/helpers.sh"

host_file() {
  printf 'schema_version = 1\nsystem = "%s"\nprofile = "workstation"\nplatform = "ubuntu-24.04"\n%s\n' "$system" "${2:-}" \
    >"$up_inst/hosts/$1.toml"
}
mkdir -p "$up_inst/hosts"
host_file example-host
host_file other-host 'tags = ["gpu"]'
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "chore: two machines"
git -C "$up_inst" push -q origin HEAD:main

# --- uncommitted edits in components/NAME --------------------------------------------------------
mkdir -p "$up_inst/components/example-notes"
printf '{ ... }:\n{\n  dotsteward.components.example-notes = { };\n}\n' >"$up_inst/components/example-notes/default.nix"
component_entry example-notes '{"method": "deb", "install": {"apt": ["example-notes"]}}'
enable_component example-notes
printf '# an edit of the agent, not committed\n' >>"$up_inst/components/example-notes/default.nix"
head=$(head_oid)
assert_exit 3 remove example-notes --publish --json
assert_stdout_json '[.ask[].code] == ["untracked-files"] and .ask[0].paths == ["components/example-notes/default.nix"]'
assert_contains "$(<"$up_inst/components/example-notes/default.nix")" "an edit of the agent"
git -C "$up_inst" add components/example-notes/default.nix
assert_exit 3 remove example-notes --publish
assert_contains "$(<"$up_inst/components/example-notes/default.nix")" "an edit of the agent"
assert_eq "$head" "$(head_oid)" "no commit"
git -C "$up_inst" reset -q --hard

# --- a table for every machine -------------------------------------------------------------------
enable_component example-viewer
assert_exit 3 add example-viewer --here --publish --json
assert_stdout_json '[.ask[].code] == ["scope-narrowed"] and .ask[0].dropped == {machines: ["other-host"]}'
assert_exit 3 add example-viewer --tags gpu --publish --json
assert_stdout_json '.ask[0].dropped == {machines: ["example-host"]}'
toml_at work '.components["example-viewer"] == {enable: true}'
component_entry example-tool '{"method": "nix", "install": {"packages": ["example-tool"]}}'
enable_component example-tool
assert_exit 3 add example-tool --here --publish --json
assert_stdout_json '[.ask[].code] == ["scope-narrowed", "profile-removal"] and .ask[1].machines == ["other-host"]'
assert_exit 0 add example-tool --here --replace-scope --publish
toml_at HEAD '.components["example-tool"] == {enable: true, machines: ["example-host"]}'

# --- --keep-here only where the component applies -----------------------------------------------
component_entry example-elsewhere '{"method": "nix", "install": {"packages": ["example-elsewhere"]}}'
enable_component example-elsewhere 'machines = ["other-host"]'
component_entry example-gpu '{"method": "nix", "install": {"packages": ["example-gpu"]}}'
enable_component example-gpu 'tags = ["gpu"]'
component_entry example-never '{"method": "nix", "install": {"packages": ["example-never"]}}'
enable_component example-never
printf '\n[declined]\ncomponents = ["example-never"]\n' >>"$up_inst/hosts/example-host.toml"
git -C "$up_inst" commit -q -am "chore: never example-never here"
git -C "$up_inst" push -q origin HEAD:main
head=$(head_oid)
assert_exit 1 remove example-elsewhere --keep-here --publish
assert_contains "$DS_STDERR" "example-elsewhere does not apply on this machine"
assert_contains "$DS_STDERR" "--uninstall"
assert_exit 1 remove example-gpu --keep-here --publish
assert_contains "$DS_STDERR" "tags"
assert_exit 1 remove example-never --keep-here --publish
assert_contains "$DS_STDERR" "Never"
assert_contains "$DS_STDERR" "dotsteward add example-never"
assert_eq "$head" "$(head_oid)" "no commit"
# The question of a plain remove offers --keep-here only where the component is here.
assert_exit 3 remove example-elsewhere --publish --json
assert_stdout_json '.ask[0].message | test("--keep-here") | not'
# Here: it stays here, and the machines that lose it are named.
component_entry example-all '{"method": "nix", "install": {"packages": ["example-all"]}}'
enable_component example-all
assert_exit 0 remove example-all --keep-here --publish --json
assert_stdout_json '.dropped_machines == ["other-host"]'
assert_contains "$DS_STDERR" "other-host loses it"
toml_at HEAD '.components["example-all"] == {enable: true, machines: ["example-host"]}'
# This machine needs its host file to be named in machines.
component_entry example-nohost '{"method": "nix", "install": {"packages": ["example-nohost"]}}'
enable_component example-nohost
git -C "$up_inst" rm -q hosts/example-host.toml
git -C "$up_inst" commit -q -m "chore: no host file here"
git -C "$up_inst" push -q origin HEAD:main
assert_exit 2 remove example-nohost --keep-here --publish
assert_contains "$DS_STDERR" "hosts/example-host.toml"
host_file example-host
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "chore: the host file again"
git -C "$up_inst" push -q origin HEAD:main

# --- tags: the way on ---------------------------------------------------------------------------
assert_exit 0 add example-gpu --also-here --publish
assert_contains "$DS_STDOUT" "does not apply on this machine (tags: gpu"
assert_contains "$DS_STDOUT" "hosts/example-host.toml"
assert_contains "$DS_STDOUT" "--replace-scope"
