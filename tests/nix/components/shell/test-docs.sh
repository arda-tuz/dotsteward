# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2088 # "~/..." needles are literal text
# The shell component documents itself (3.5): README.md with its methods,
# options, files and verification status, and maintenance.md for updates.
dir=$DS_REPO_ROOT/modules/components/shell

for file in default.nix package.nix starship-package.nix zshrc.nix seed.json README.md maintenance.md; do
  [[ -s $dir/$file ]] || ds_fail "missing modules/components/shell/$file"
done

readme=$(<"$dir/README.md")
for needle in "## Methods" "## Options" "autosuggestions" "syntaxHighlighting" "## Files" "~/.zshrc" \
  "~/.config/starship.toml" "/etc/shells" "## Verification"; do
  assert_contains "$readme" "$needle" "README.md"
done
grep -Eq '^(- )?.*(verified on [0-9]{4}-[0-9]{2}-[0-9]{2} from |not verified)' "$dir/README.md" ||
  ds_fail "README.md states no verification status (verified on <date> from <source>, or not verified)"

maintenance=$(<"$dir/maintenance.md")
for needle in "nix_packages.starship" "source_nix_sha256" "cargo_nix_sha256" "tag_revision" "github-release"; do
  assert_contains "$maintenance" "$needle" "maintenance.md"
done
