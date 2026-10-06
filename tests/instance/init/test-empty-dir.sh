# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs and literal texts are single-quoted on purpose
# I1 (SPEC 10.3): init of a missing and of an empty directory. The result is
# the template with the files init writes (workstation.toml, the locks,
# flake.nix), the flake.lock of `nix flake lock` and the .dotsteward/ mirrors
# of `dotsteward sync --nix`, committed once on main with the user's own git
# identity, and it passes the instance contract (static, the offline pins
# check, settings validate, the tree scan). The Nix steps run in a temporary
# directory, never in DIR, and that directory is gone afterwards.
# shellcheck source=tests/instance/init/helpers.sh
source "$DS_REPO_ROOT/tests/instance/init/helpers.sh"

init_use_nix
written=(workstation.toml versions.lock.json agent/skills.lock.json flake.nix)

# assert_template_copy DIR: every template file other than the written ones
# is in DIR byte for byte with its mode.
assert_template_copy() {
  local file name skip
  while IFS= read -r -d '' file; do
    file=${file#./}
    skip=0
    for name in "${written[@]}"; do
      [[ $file != "$name" ]] || skip=1
    done
    ((skip)) && continue
    [[ -f $1/$file ]] || ds_fail "$file of the template is missing in $1"
    cmp -s "$tpl/$file" "$1/$file" || ds_fail "$file differs from the template"
    assert_eq "$(stat -c %a "$tpl/$file")" "$(stat -c %a "$1/$file")" "mode of $file"
  done < <(cd "$tpl" && find . -type f -print0)
}

# assert_committed DIR: one commit on main with the user's identity, holding
# every file of DIR, and a clean tree.
assert_committed() {
  local dir=$1
  assert_eq main "$(git -C "$dir" symbolic-ref --short HEAD)" "branch"
  assert_eq 1 "$(git -C "$dir" rev-list --count HEAD)" "one commit"
  assert_eq "chore: initialize dotsteward instance" "$(git -C "$dir" log -1 --format=%B | sed '/^$/d')" "commit message"
  assert_eq "dotsteward-test <dotsteward-test@example.invalid>" "$(git -C "$dir" log -1 --format='%an <%ae>')" "author"
  assert_eq "dotsteward-test <dotsteward-test@example.invalid>" "$(git -C "$dir" log -1 --format='%cn <%ce>')" "committer"
  assert_eq "" "$(git -C "$dir" status --porcelain --untracked-files=all)" "clean tree"
  assert_eq "$(cd "$dir" && find . -path ./.git -prune -o -type f -print | sed 's|^\./||' | LC_ALL=C sort)" \
    "$(git -C "$dir" ls-files | LC_ALL=C sort)" "every file is committed"
  assert_eq "" "$(git -C "$dir" remote)" "no remote is added"
}

# --- a missing directory below HOME, no component ---------------------------------

dir=$HOME/workstation
init_run 0 --dir "$dir" --remote "$init_remote" --non-interactive
assert_contains "$DS_STDOUT" "[dotsteward] Initialized the dotsteward instance in $dir"
assert_contains "$DS_STDOUT" "[dotsteward] Components: none"
assert_contains "$DS_STDOUT" "[dotsteward] Committed $(git -C "$dir" rev-parse HEAD | cut -c1-12) chore: initialize dotsteward instance"
assert_contains "$DS_STDOUT" "[dotsteward] Next steps:"
assert_contains "$DS_STDOUT" "git -C $dir remote add origin $init_remote && git -C $dir push -u origin main"
assert_contains "$DS_STDOUT" "cd $dir && ./bootstrap.sh --profile fresh"
assert_contains "$DS_STDOUT" "cd $dir && ./rebuild.sh --profile workstation --switch && ./.dotsteward/cli.sh e2e --profile workstation"
# The output of the steps: the mirrors sync and the pins.
assert_contains "$DS_STDOUT" "[dotsteward] Wrote mirror .dotsteward/manifest.x86_64-linux.json"
assert_contains "$DS_STDOUT" "[pins]"

assert_template_copy "$dir"
assert_eq "" "$(grep -n 'dotsteward:template' "$dir/workstation.toml" || true)" "the template marker is gone"
config=$(toml_json "$dir/workstation.toml")
assert_json - '.schema_version == 1' <<<"$config"
assert_jq - '.identity == { username: "dotsteward-test", home: $home }' --arg home "$HOME" <<<"$config"
assert_json - '.instance == { name: "workstation", remote: "git@github.com:alice/workstation.git", checkout: "~/workstation" }' \
  <<<"$config"
assert_json - '.nix == { systems: ["x86_64-linux"], allow_unfree: false, state_version: "26.05" }' <<<"$config"
assert_json - '.profiles == {
  names: ["workstation", "fresh"], default: "workstation", check: "workstation", bootstrap: "fresh",
  workstation: { mode: "adopt" }, fresh: { mode: "fresh" }
}' <<<"$config"
assert_json - 'has("components") | not' <<<"$config"
assert_json - '.upstream == { contribute: "fork" }' <<<"$config"

# No component: the locks are the template's (the template generated_at kept).
cmp -s "$tpl/versions.lock.json" "$dir/versions.lock.json" || ds_fail "versions.lock.json is not the template's"
cmp -s "$tpl/agent/skills.lock.json" "$dir/agent/skills.lock.json" || ds_fail "skills.lock.json is not the template's"
assert_eq "" "$(flake_inputs_block "$dir/flake.nix")" "no component input"
cmp -s "$tpl/flake.nix" "$dir/flake.nix" || ds_fail "flake.nix is not the template's"
assert_json "$dir/flake.lock" '.nodes.root.inputs | keys == ["dotsteward", "home-manager", "nixpkgs"]'
for mirror in manifest.x86_64-linux.json stage0.linux.env; do
  [[ -f $dir/.dotsteward/$mirror ]] || ds_fail "the mirror .dotsteward/$mirror is missing"
done
assert_committed "$dir"
instance_contract "$dir" x86_64-linux

# The Nix steps ran on the staged instance in a temporary directory, in
# order: lock, mirrors, the pins sync and the pins check.
stage=$(<"$DS_STUB_STATE/nix/staged/1.root")
[[ $stage == "$(cd "$TMPDIR" && pwd -P)"/dotsteward-init.* ]] || ds_fail "the instance was not staged in TMPDIR: $stage"
[[ ! -e $stage ]] || ds_fail "the temporary directory remains: $stage"
assert_eq "" "$(init_temp_dirs)" "no temporary directory is left"
nix_calls=$(ds_calls_of nix | sed -e "s|$(printf '%q' "$stage")|STAGE|g")
assert_eq "nix --extra-experimental-features nix-command\\ flakes flake lock STAGE
nix --extra-experimental-features nix-command\\ flakes eval --json --no-update-lock-file STAGE#dotstewardMirrors
nix --extra-experimental-features nix-command\\ flakes eval --json --no-update-lock-file STAGE#lib.pinnedVersions
nix --extra-experimental-features nix-command\\ flakes eval --json --no-update-lock-file STAGE#lib.pinnedVersions" \
  "$nix_calls" "the Nix steps"

# --- an existing empty directory outside HOME, every catalog component -------------

dir=$DS_TEST_ROOT/instances/station
mkdir -p "$dir"
init_run 0 --dir "$dir" --remote "$init_remote" --components "$(
  IFS=,
  echo "${init_catalog[*]}"
)" --allow-unfree --non-interactive
assert_contains "$DS_STDOUT" "[dotsteward] Components: shell, herdr, claude-code, codex, opencode-pi, vscode"
assert_template_copy "$dir"
config=$(toml_json "$dir/workstation.toml")
assert_jq - '.instance == { name: "station", remote: "git@github.com:alice/workstation.git", checkout: $dir }' \
  --arg dir "$dir" <<<"$config"
assert_json - '.nix.allow_unfree == true' <<<"$config"
assert_json - '.components == {
  order: ["shell", "herdr", "claude-code", "codex", "opencode-pi", "vscode"],
  shell: { enable: true }, herdr: { enable: true }, "claude-code": { enable: true },
  codex: { enable: true }, "opencode-pi": { enable: true }, vscode: { enable: true }
}' <<<"$config"
# The seeds are in the locks and the herdr input is in the flake (the
# composition itself: test-seeds.sh and test-flake-inputs.sh); the mirrors
# filled the skills lock values from the versions lock.
assert_json "$dir/versions.lock.json" '.nix_packages | keys == ["herdr", "pi", "starship", "tomlkit", "zsh"]'
assert_json "$dir/agent/skills.lock.json" '.nix_tools.pi == "1.0.1"'
assert_jq "$dir/agent/skills.lock.json" \
  '.release_tools.opencode.version == $lock[0].agent_tools.opencode.minimum_version' \
  --slurpfile lock "$dir/versions.lock.json"
assert_json "$dir/flake.lock" '.nodes.root.inputs | keys == ["dotsteward", "herdr", "home-manager", "nixpkgs"]'
assert_json "$dir/.dotsteward/manifest.x86_64-linux.json" \
  '[.components[].name] == ["shell", "herdr", "claude-code", "codex", "opencode-pi", "vscode"]'
assert_committed "$dir"
instance_contract "$dir" x86_64-linux
assert_eq "" "$(init_temp_dirs)" "no temporary directory is left"
