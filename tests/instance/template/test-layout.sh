# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The files of template/ (SPEC 10.1): exactly the listed paths, no symbolic
# links, executable exactly where the file is a script, text that ends with
# a newline and has no carriage returns.
# shellcheck source=tests/instance/template/helpers.sh
source "$DS_REPO_ROOT/tests/instance/template/helpers.sh"

[[ -d $tpl ]] || ds_fail "template/ is missing"

expected_files=(
  .dotsteward/cli.sh
  .gitignore
  AGENTS.md
  README.md
  agent/overlays/README.md
  agent/skills.lock.json
  agent/skills/.gitkeep
  bootstrap.sh
  components/README.md
  components/example/default.nix.disabled
  flake.nix
  home.nix
  home/AGENTS.md
  local-maintained-files/buffer.toml
  rebuild.sh
  rollback.sh
  tests/README.md
  update.sh
  versions.lock.json
  workstation.toml
)
executables=(.dotsteward/cli.sh bootstrap.sh rebuild.sh rollback.sh update.sh)

actual=$(cd "$tpl" && find . -mindepth 1 ! -type d -printf '%P\n' | LC_ALL=C sort)
assert_eq "$(printf '%s\n' "${expected_files[@]}" | LC_ALL=C sort)" "$actual" "template files"

links=$(cd "$tpl" && find . -type l -printf '%P\n')
assert_eq "" "$links" "symbolic links in template/"

# Only directories that hold a listed file: no empty directory, which git
# would drop anyway.
empty=$(cd "$tpl" && find . -mindepth 1 -type d -empty -printf '%P\n')
assert_eq "" "$empty" "empty directories in template/"

is_executable_entry() {
  local entry
  for entry in "${executables[@]}"; do
    [[ $entry == "$1" ]] && return 0
  done
  return 1
}

for file in "${expected_files[@]}"; do
  path=$tpl/$file
  # Only the executable bits: the other bits follow the umask, and the
  # Nix store drops write bits.
  bits=$((8#$(stat -c %a -- "$path")))
  if is_executable_entry "$file"; then
    ((bits & 8#100)) || ds_fail "$file is not executable"
    # The shebang as committed, or patched to a store bash inside the Nix
    # build sandbox (bootstrap.sh is compared byte for byte elsewhere).
    first=$(head -n 1 "$path")
    [[ $first == '#!/usr/bin/env bash' || $first =~ ^#!/nix/store/[^[:space:]]+/bin/bash$ ]] ||
      ds_fail "$file: unexpected shebang [$first]"
  else
    ((!(bits & 8#111))) || ds_fail "$file is executable"
  fi
  [[ ! -s $path || $(tail -c 1 "$path" | od -An -c | tr -d ' ') == '\n' ]] ||
    ds_fail "$file does not end with a newline"
  if grep -q $'\r' "$path"; then
    ds_fail "$file contains a carriage return"
  fi
done

# The placeholder of the vendored skills directory is empty.
[[ ! -s $tpl/agent/skills/.gitkeep ]] || ds_fail "agent/skills/.gitkeep is not empty"

# home/AGENTS.md is the one shared rules sentence.
assert_eq "Shared rules for your coding agents." "$(<"$tpl/home/AGENTS.md")" "home/AGENTS.md"
