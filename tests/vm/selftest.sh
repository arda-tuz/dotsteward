#!/usr/bin/env bash
# Self-test of the VM harness in tests/vm. It never boots a virtual machine,
# never needs approval of the VM phase and never runs sudo: QEMU and ssh are
# fakes (tests/vm/fakes), the image download goes through the harness curl
# stub, and only qemu-img, xorriso and ssh-keygen run for real (each part is
# skipped when its tool is missing).
#
# Usage: bash tests/vm/selftest.sh
#
# Steps: every shell file under tests/vm parses (bash -n) and passes the
# linter (shellcheck pinned by flake.lock when Nix is available, else the one
# on PATH), then `tests/run.sh tests/vm` runs the test files.
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
cd "$repo_root"

files=()
while IFS= read -r -d '' file; do
  files+=("$file")
done < <(find tests/vm -type f \( -name '*.sh' -o -path 'tests/vm/fakes/*' \) -print0 | LC_ALL=C sort -z)
((${#files[@]})) || {
  echo 'selftest: no shell files found under tests/vm' >&2
  exit 1
}

echo "selftest: syntax of ${#files[@]} files"
for file in "${files[@]}"; do
  bash -n "$file"
done

for file in tests/vm/fakes/*; do
  [[ $file == *.sh || -x $file ]] || {
    echo "selftest: fake is not executable: $file" >&2
    exit 1
  }
done

echo 'selftest: shellcheck'
if command -v nix >/dev/null 2>&1; then
  nix --extra-experimental-features 'nix-command flakes' run --inputs-from . nixpkgs#shellcheck -- \
    -x "${files[@]}"
elif command -v shellcheck >/dev/null 2>&1; then
  echo 'selftest: Nix not found, using shellcheck from PATH' >&2
  shellcheck -x "${files[@]}"
else
  echo 'selftest: shellcheck is required (Nix or shellcheck on PATH)' >&2
  exit 1
fi

echo 'selftest: tests'
bash tests/run.sh tests/vm
