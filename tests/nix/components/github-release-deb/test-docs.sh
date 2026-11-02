# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness
# shellcheck disable=SC2016 # needles are literal Markdown text
# The documentation of the github-release-deb components: each README.md
# names its package, the deb method, its pin, the local APT bridge with
# plain `apt upgrade`, `install --component` for an adopted machine, the
# commands and the E2E hook, the darwin limit, the preselection line of
# `dotsteward init` (Linux only) and its verification record;
# maintenance.md names the github-release adapter and the asset.
# shellcheck source=tests/nix/components/github-release-deb/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/github-release-deb/helpers.sh"

for name in pdfcraft gridcraft wordcraft deckcraft craft-anything; do
  dir=$DS_REPO_ROOT/modules/components/$name
  readme=$dir/README.md
  maintenance=$dir/maintenance.md
  [[ -s $readme ]] || ds_fail "missing modules/components/$name/README.md"
  [[ -s $maintenance ]] || ds_fail "missing modules/components/$name/maintenance.md"
  [[ $(head -n 1 "$readme") == "# $name" ]] || ds_fail "$name: README.md does not start with # $name"

  text=$(<"$readme")
  for needle in \
    '`deb`' "\`desktop_packages.$name\`" "https://github.com/storytold/$name" \
    "\`$name-<version>-linux-x86_64.deb\`" 'SHA256SUMS.txt' 'local APT bridge' '`apt update && apt upgrade`' \
    "dotsteward install --profile <profile> --component $name" "\`$name-cli --version\`" \
    'darwin: not supported' '`github-release`' 'unattended'; do
    assert_contains "$text" "$needle" "$name README.md"
  done
  grep -qxF 'Preselected for new instances on: `x86_64-linux`.' "$readme" ||
    ds_fail "$name: README.md lacks the preselection line"
  grep -qE 'verified on [0-9]{4}-[0-9]{2}-[0-9]{2} from ' "$readme" ||
    ds_fail "$name: README.md lacks the verification record"

  text=$(<"$maintenance")
  for needle in "\`desktop_packages.$name\`" '`github-release`' "storytold/$name" \
    "\`$name-{version}-linux-x86_64.deb\`" 'SHA256SUMS.txt'; do
    assert_contains "$text" "$needle" "$name maintenance.md"
  done
done
