# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and vscode_* variables come from the harness and helpers.sh
# shellcheck disable=SC2016,SC2088 # needles are literal Markdown text
# The vscode documentation: README.md says what is installed
# on each platform and by which methods, names the settings target and its
# paths, the set_default_editor option, the lock paths, and the verification
# status of the darwin archive facts (the download URL and the
# Info.plist version key) with date and source; maintenance.md says how the
# pins are refreshed.
# shellcheck source=tests/nix/components/vscode/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/vscode/helpers.sh"

readme=$vscode_component/README.md
maintenance=$vscode_component/maintenance.md
[[ -s $readme ]] || ds_fail "missing modules/components/vscode/README.md"
[[ -s $maintenance ]] || ds_fail "missing modules/components/vscode/maintenance.md"

text=$(<"$readme")
for needle in \
  '`deb`' '`app-archive`' '`external`' \
  'vscode-settings' '~/.config/Code/User/settings.json' '~/Library/Application Support/Code/User/settings.json' \
  'set_default_editor' 'EDITOR' 'VISUAL' 'GIT_EDITOR' '`code --wait`' \
  'desktop_packages.vscode' 'desktop_packages.vscode-darwin-arm64' \
  'Visual Studio Code.app' 'CFBundleShortVersionString' 'Contents/Resources/app/bin/code'; do
  assert_contains "$text" "$needle" "README.md"
done

# The section 14 record: "verified on <date> from <source>", or "not
# verified" with the fallback.
grep -qE 'verified on [0-9]{4}-[0-9]{2}-[0-9]{2} from ' "$readme" ||
  grep -qi 'not verified' "$readme" || ds_fail "README.md lacks the verification record"

text=$(<"$maintenance")
for needle in \
  'https://update.code.visualstudio.com/api/update/linux-deb-x64/stable/latest' \
  'https://update.code.visualstudio.com/api/update/darwin-arm64/stable/latest' \
  'productVersion' 'sha256hash' 'official-manifest'; do
  assert_contains "$text" "$needle" "maintenance.md"
done
