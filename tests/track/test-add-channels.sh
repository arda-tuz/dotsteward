# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# The channel of `dotsteward add NAME` decides what it writes, and only a clear one writes:
# - no catalog component and no component of the instance by that name, and no channel given: the
#   channel needs research, so add writes nothing and exits 3 with channel-unknown, which names the
#   ways on (an APT package, a nixpkgs package, a component written by the maintain skill);
# - --apt PACKAGE: plain APT packages that a source of this machine offers or that are installed,
#   as a deb component of the instance in components/NAME/default.nix; a package that neither is
#   is refused before anything is written;
# - --nix ATTRIBUTE: a nixpkgs package as a nix component of the instance;
# - components/NAME/default.nix that the agent wrote: add enables it and commits it with the table.
# shellcheck source=tests/track/helpers.sh
source "$DS_REPO_ROOT/tests/track/helpers.sh"

head=$(head_oid)
clear_log
assert_exit 3 add example-notes --json
assert_stdout_json '.command == "add" and .component == "example-notes" and .exit_code == 3'
assert_stdout_json '[.ask[].code] == ["channel-unknown"]'
assert_stdout_json '.ask[0].message | test("--apt") and test("--nix") and test("components/example-notes/default.nix")'
assert_eq "$head" "$(head_oid)" "no commit"
assert_eq "" "$(git -C "$up_inst" status --porcelain)" "nothing written"
assert_no_step '^static '
assert_exit 3 add example-notes
assert_contains "$DS_STDERR" "channel-unknown"

# An APT package that no source offers and that is not installed: refused, nothing written.
assert_exit 1 add example-notes --apt example-notes
assert_contains "$DS_STDERR" "example-notes"
assert_eq "" "$(git -C "$up_inst" status --porcelain)" "nothing written"

# Offered by a source of this machine: a deb component of the instance.
ds_apt_available example-notes 2.1-1
ds_apt_available example-notes-data 2.1-1
assert_exit 0 add example-notes --apt example-notes --apt example-notes-data --command example-notes --publish
assert_eq "feat: track example-notes" "$(git -C "$up_inst" log -1 --format=%s)"
assert_eq "$(head_oid)" "$(remote_oid)" "published"
toml_at HEAD '.components["example-notes"] == {enable: true}'
nix_file=$(git -C "$up_inst" show HEAD:components/example-notes/default.nix)
assert_contains "$nix_file" 'dotsteward.components.example-notes = {'
assert_contains "$nix_file" 'method = lib.mkDefault "deb";'
assert_contains "$nix_file" 'platforms = [ "linux" ];'
assert_contains "$nix_file" 'apt = [ "example-notes" "example-notes-data" ];'
assert_contains "$nix_file" 'pin = null;'
assert_contains "$nix_file" 'commands = [ "example-notes" ];'
assert_not_contains "$nix_file" "$HOME"
# An installed package counts as well, even when no source offers it any more.
ds_dpkg_installed example-legacy 1.0-1
assert_exit 0 add example-legacy --apt example-legacy --publish
toml_at HEAD '.components["example-legacy"] == {enable: true}'

# A nixpkgs package: a nix component of the instance.
assert_exit 0 add example-grep --nix ripgrep --command rg --publish
nix_file=$(git -C "$up_inst" show HEAD:components/example-grep/default.nix)
assert_contains "$nix_file" 'method = lib.mkDefault "nix";'
assert_contains "$nix_file" 'packages = [ pkgs.ripgrep ];'
assert_contains "$nix_file" 'commands = [ "rg" ];'
assert_exit 2 add example-bad --nix 'rip grep'
assert_exit 2 add example-viewer --nix ripgrep
assert_contains "$DS_STDERR" "catalog component"
assert_exit 2 add example-both --nix ripgrep --apt example-notes

# A component the agent wrote by the maintain skill: add enables it and commits its files with
# the table, since they are this transaction.
mkdir -p "$up_inst/components/example-tool"
printf '{ ... }:\n{\n  dotsteward.components.example-tool = { };\n}\n' >"$up_inst/components/example-tool/default.nix"
printf 'notes\n' >"$up_inst/components/example-tool/README.md"
assert_exit 0 add example-tool --publish
assert_eq "feat: track example-tool" "$(git -C "$up_inst" log -1 --format=%s)"
assert_eq "components/example-tool/README.md components/example-tool/default.nix workstation.toml" \
  "$(git -C "$up_inst" diff --name-only HEAD^ HEAD -- . ':!.dotsteward' | tr '\n' ' ' | sed 's/ $//')"
assert_eq "" "$(git -C "$up_inst" status --porcelain)" "the checkout is clean"
# A scaffold never replaces a file the instance has.
assert_exit 1 add example-tool --apt example-notes
assert_contains "$DS_STDERR" "components/example-tool/default.nix"
