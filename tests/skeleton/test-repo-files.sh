# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Repository skeleton: metadata files, discovery-friendly Nix sources and
# shell entry points. Runs without Nix (also inside the build sandbox).

root=$DS_REPO_ROOT

for file in flake.nix flake.lock VERSION LICENSE README.md CONTRIBUTING.md SECURITY.md \
  .gitignore .editorconfig nix/outputs.nix nix/packages/dotsteward.nix lib/default.nix \
  nix/checks/skeleton.nix cli/dotsteward cli/commands/version.sh tests/run.sh \
  tests/lib/harness.sh tests/lib/assert.sh; do
  [[ -f $root/$file ]] || ds_fail "missing $file"
done

# No changelog file anywhere (releases use generated notes).
assert_eq "" "$(find "$root" -path "$root/.git" -prune -o -iname 'changelog*' -print)"

# LICENSE: MIT, held by the contributors collectively.
assert_eq "MIT License" "$(head -n 1 "$root/LICENSE")"
assert_contains "$(<"$root/LICENSE")" "Copyright (c) 2026 dotsteward contributors"
assert_contains "$(<"$root/LICENSE")" 'THE SOFTWARE IS PROVIDED "AS IS"'

# .gitignore holds exactly the documented entries.
assert_eq "result*
.direnv/
__pycache__/
*.pyc
.env*
.work/
.claude/settings.local.json" "$(grep -v -e '^#' -e '^$' "$root/.gitignore")"

# flake.nix: the two inputs, home-manager following nixpkgs, both pinned to a
# full revision, and outputs delegated to nix/outputs.nix.
flake=$(<"$root/flake.nix")
[[ $flake =~ nixpkgs\.url\ =\ \"github:NixOS/nixpkgs/[0-9a-f]{40}\" ]] || ds_fail "nixpkgs is not pinned to a revision"
[[ $flake =~ url\ =\ \"github:nix-community/home-manager/[0-9a-f]{40}\" ]] || ds_fail "home-manager is not pinned to a revision"
assert_contains "$flake" 'inputs.nixpkgs.follows = "nixpkgs";'
assert_contains "$flake" 'outputs = inputs: import ./nix/outputs.nix inputs;'
assert_json "$root/flake.lock" '(.nodes.root.inputs | keys) == ["home-manager", "nixpkgs"]'
assert_json "$root/flake.lock" '.nodes["home-manager"].inputs.nixpkgs == ["nixpkgs"]'
for input in nixpkgs home-manager; do
  rev=$(sed -n "s|.*$input/\([0-9a-f]\{40\}\)\".*|\1|p" "$root/flake.nix" | head -n 1)
  assert_json "$root/flake.lock" ".nodes[\"$input\"].locked.rev == \"$rev\"" "$input lock matches flake.nix"
done

# Discovery: checks and catalog are read from directories, never listed.
outputs=$(<"$root/nix/outputs.nix")
assert_contains "$outputs" "builtins.readDir ./checks"
assert_contains "$outputs" '"x86_64-linux"'
assert_contains "$outputs" '"aarch64-darwin"'
assert_contains "$outputs" "formatter = forAllSystems (system: (pkgsFor system).nixfmt);"

# lib/default.nix exports every library name from the start.
for name in mkInstance mkNpmBundle catalog contract pinAt platform version mkCli; do
  grep -Eq "^[[:space:]]+$name =" "$root/lib/default.nix" || ds_fail "lib/default.nix does not export $name"
done

# Shell entry points are executable, start with the portable shebang and
# use strict mode; every shell file parses.
for file in cli/dotsteward cli/commands/version.sh tests/run.sh; do
  [[ -x $root/$file ]] || ds_fail "$file is not executable"
  # The Nix check runs on a copy whose shebangs patchShebangs rewrote.
  [[ $(head -n 1 "$root/$file") =~ ^#!(/usr/bin/env\ bash|/nix/store/[a-z0-9]{32}-bash-[^/]+/bin/bash)$ ]] ||
    ds_fail "$file does not start with #!/usr/bin/env bash"
  grep -q '^set -Eeuo pipefail$' "$root/$file" || ds_fail "$file does not use strict mode"
done
while IFS= read -r -d '' file; do
  bash -n "$file" || ds_fail "syntax error in ${file#"$root"/}"
done < <(find "$root/cli" "$root/tests" -type f \( -name '*.sh' -o -path "$root/cli/dotsteward" \) -print0)

# Text files are ASCII only and end with a newline.
for file in VERSION LICENSE README.md CONTRIBUTING.md SECURITY.md .gitignore .editorconfig \
  flake.nix nix/outputs.nix nix/packages/dotsteward.nix lib/default.nix nix/checks/skeleton.nix \
  cli/dotsteward cli/commands/version.sh tests/run.sh tests/lib/harness.sh tests/lib/assert.sh; do
  if LC_ALL=C grep -q '[^[:print:][:space:]]' "$root/$file"; then
    ds_fail "$file contains non-ASCII bytes"
  fi
  [[ -z $(tail -c 1 "$root/$file") ]] || ds_fail "$file does not end with a newline"
done
