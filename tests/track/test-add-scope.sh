# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# add says what it does to the scope of a component and whether the component applies here:
# - a scope option that would drop machines, tags or profiles from a list the table has stops with
#   scope-narrowed, naming what would drop; --also-here adds this machine, --replace-scope confirms;
# - a component that does not apply on this machine (machines, tags, the platform) is said so,
#   with the way on; this machine's answer Never for it goes, since the owner asked to track it;
# - --machines names machines with a host file, --method one the component supports, before
#   anything runs; --apt is checked on this machine only when the component is for it;
# - --with-changes names the changes it takes along;
# - a name or a nixpkgs attribute that is a Nix keyword is refused; the uncommitted scaffold of an
#   add that went red gives way to the next add.
# shellcheck source=tests/track/helpers.sh
source "$DS_REPO_ROOT/tests/track/helpers.sh"

mkdir -p "$up_inst/hosts"
for host in example-host other-host; do
  printf 'schema_version = 1\nsystem = "%s"\nprofile = "workstation"\nplatform = "ubuntu-24.04"\n' "$system" \
    >"$up_inst/hosts/$host.toml"
done
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "chore: two machines"
git -C "$up_inst" push -q origin HEAD:main

# --- a list that would shrink --------------------------------------------------------------------
enable_component example-viewer 'machines = ["other-host"]'
head=$(head_oid)
assert_exit 0 add example-viewer --publish --json
assert_stdout_json '.here == false and .reason == "machines"'
assert_contains "$DS_STDERR" "example-viewer does not apply on this machine"
assert_contains "$DS_STDERR" "--also-here"
assert_exit 3 add example-viewer --here --publish --json
assert_stdout_json '[.ask[].code] == ["scope-narrowed"] and .ask[0].dropped == {machines: ["other-host"]}'
assert_eq "$head" "$(head_oid)" "no commit"
assert_eq "" "$(git -C "$up_inst" status --porcelain)" "nothing written"
assert_exit 0 add example-viewer --also-here --publish --json
toml_at HEAD '.components["example-viewer"].machines == ["other-host", "example-host"]'
assert_stdout_json '.here == true'
assert_exit 0 add example-viewer --here --replace-scope --publish
toml_at HEAD '.components["example-viewer"].machines == ["example-host"]'

# --- this machine said Never -------------------------------------------------------------------
mkdir -p "$fw/modules/components/example-chat"
enable_component example-chat
printf '\n[declined]\ncomponents = ["example-chat"]\n' >>"$up_inst/hosts/example-host.toml"
git -C "$up_inst" commit -q -am "chore: never example-chat here"
git -C "$up_inst" push -q origin HEAD:main
assert_exit 0 add example-chat --publish
assert_contains "$DS_STDOUT" "takes back the answer Never"
assert_not_contains "$(git -C "$up_inst" show HEAD:hosts/example-host.toml)" "example-chat"
assert_eq "feat: track example-chat" "$(git -C "$up_inst" log -1 --format=%s)"

# --- the platform --------------------------------------------------------------------------------
component_entry example-mac '{"method": "nix", "platforms": ["darwin"], "unavailable": "platform"}'
mkdir -p "$fw/modules/components/example-mac"
assert_exit 0 add example-mac --publish --json
assert_stdout_json '.here == false and .reason == "platform"'
assert_contains "$DS_STDERR" "example-mac is not available on this platform"

# --- scope values the instance does not have ------------------------------------------------------
head=$(head_oid)
assert_exit 2 add example-viewer2 --machines no-such-host
assert_contains "$DS_STDERR" "hosts/no-such-host.toml"
component_entry example-only-nix '{"method": "nix", "supported_methods": {"linux": ["nix"], "darwin": ["nix"]}}'
mkdir -p "$fw/modules/components/example-only-nix"
head=$(head_oid)
assert_exit 2 add example-only-nix --method deb
assert_contains "$DS_STDERR" "nix"
assert_eq "$head" "$(head_oid)" "no commit"
assert_eq "" "$(git -C "$up_inst" status --porcelain)" "nothing written"

# --apt for another machine is not checked against the APT of this one.
assert_exit 0 add example-remote --apt example-remote-only --machines other-host --publish
assert_contains "$DS_STDOUT" "not checked on this machine"

# --- --with-changes names what it takes along ----------------------------------------------------
mkdir -p "$up_inst/components/example-pinned"
printf '{ ... }:\n{\n  dotsteward.components.example-pinned = { };\n}\n' >"$up_inst/components/example-pinned/default.nix"
printf 'notes\n' >>"$up_inst/docs/guide.md"
assert_exit 0 add example-pinned --with-changes --publish --json
assert_stdout_json '.with_changes == ["docs/guide.md"]'
assert_contains "$DS_STDERR" "takes along: docs/guide.md"

# --- Nix keywords, and a typo that went red ----------------------------------------------------
for argv in "let --nix hello" "example-k --nix let" "example-k --nix lib.if" "example-k --nix with.hello"; do
  # shellcheck disable=SC2086 # the words of the case
  assert_exit 2 add $argv
done
assert_exit 0 add example-or --nix lib.or --no-publish
git -C "$up_inst" reset -q --hard origin/main
git -C "$up_inst" clean -qfd -- components
touch "$UP_CONTROL/static-red"
assert_exit 1 add example-typo --nix hellp
rm -f -- "$UP_CONTROL/static-red"
assert_exit 0 add example-typo --nix hello --publish
assert_contains "$(git -C "$up_inst" show HEAD:components/example-typo/default.nix)" "pkgs.hello"
