# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# shellcheck disable=SC2016 # fixture text with a literal $ is written on purpose
# Command-name rule: framework code, tests, stubs and docs name
# only catalog commands, the platform tools of tests/static/allowed-commands.txt
# and the synthetic fixture names. Command words come from stub file names,
# require_command and `command -v` arguments, and fenced shell blocks in
# Markdown files.
# shellcheck source=tests/static/helpers.sh
source "$DS_REPO_ROOT/tests/static/helpers.sh"

# The public list holds the spec's platform tools and the coreutils and
# findutils names.
list=$DS_REPO_ROOT/tests/static/allowed-commands.txt
[[ -f $list ]] || ds_fail "missing $list"
words=$(grep -v '^[[:space:]]*\(#\|$\)' "$list" | tr -s '[:space:]' '\n')
for word in sudo apt-get apt-cache dpkg dpkg-query dpkg-deb getent chsh id sw_vers dscl xcode-select \
  plutil hdiutil ditto unzip tar curl git gh nix nix-store ssh install mktemp flock jq python3 bash \
  shellcheck actionlint nixfmt cat sort sha256sum find xargs; do
  grep -qxF -- "$word" <<<"$words" || ds_fail "allowed-commands.txt lacks $word"
done
# No catalog or fixture name is listed as a platform tool, and no entry is
# listed twice.
for word in claude codex herdr zsh starship opencode pi code example-app example-term alpha beta gamma delta; do
  ! grep -qxF -- "$word" <<<"$words" || ds_fail "allowed-commands.txt lists $word"
done
assert_eq "" "$(sort <<<"$words" | uniq -d)" "duplicate entries"

# The real tree follows the rule.
cd "$DS_REPO_ROOT"
assert_exit 0 static --sandbox --only command-names
assert_contains "$DS_STDOUT" "[dotsteward] static checks passed (framework): command-names"

fw=$DS_TEST_ROOT/fw
framework_copy "$fw"
# An unknown word, built at run time so this file never names it.
unknown=zz"qx"tool

# Accepted forms: catalog, platform and fixture names, builtins, keywords,
# variables, repository-relative scripts, prompts, comments, prefixes.
cat >"$fw/docs-ok.md" <<MD
# Example

\`\`\`sh
# $unknown in a comment is prose
TZ=UTC git log --oneline | head -n 3 && echo done
sudo apt-get install --no-install-recommends example-app
env DOTSTEWARD_CLI=/tmp/x nix run . -- --help
codex --version; claude --version || true
cd /tmp && ./bootstrap.sh --profile workstation
for name in alpha beta; do printf '%s\n' "\$name"; done
"\$HOME/bin/tool" --flag
\`\`\`

\`\`\`console
\$ herdr --version
$unknown 1.0 is output, not a command
\`\`\`

\`\`\`text
$unknown appears in plain text blocks freely
\`\`\`

Prose may say $unknown too.
MD
printf '#!/usr/bin/env bash\nrequire_command "$%s"\ncommand -v -- jq >/dev/null\n# require_command %s in a comment\n' \
  tool "$unknown" >"$fw/cli/commands/zz-ok.sh"
chmod 0755 "$fw/cli/commands/zz-ok.sh"
assert_exit 0 fw_static "$fw" --sandbox --only command-names

# Each source of command words is checked; the word itself is never printed
# (it may be a private name), only where it is.
{
  printf '\n```bash\nls -l\n%s --run\n```\n' "$unknown"
  printf '\n```console\n$ sudo %s install\n```\n' "$unknown"
  printf '\n```sh\ngit status | xargs -0 %s\n```\n' "$unknown"
} >"$fw/docs-bad.md"
printf '#!/usr/bin/env bash\n' >"$fw/tests/lib/stubs/$unknown"
chmod 0755 "$fw/tests/lib/stubs/$unknown"
printf '#!/usr/bin/env bash\n%s %s\nif command -v %s >/dev/null; then :; fi\n' \
  require_command "$unknown" "'$unknown'" >"$fw/cli/commands/zz-bad.sh"
chmod 0755 "$fw/cli/commands/zz-bad.sh"
printf '{ ... }: "command -v %s"\n' "$unknown" >"$fw/zz-bad.nix"
assert_exit 1 fw_static "$fw" --sandbox --only command-names
for location in "docs-bad.md:4: a fenced shell block" "docs-bad.md:8: a fenced shell block" \
  "docs-bad.md:12: a fenced shell block" "tests/lib/stubs (entry " \
  "cli/commands/zz-bad.sh:2: an argument of require_command" "cli/commands/zz-bad.sh:3: an argument of command -v" \
  "zz-bad.nix:1: an argument of command -v"; do
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: static command-names: $location"
done
assert_contains "$DS_STDERR" "): a stub file name names a command outside the catalog, tests/static/allowed-commands.txt and the fixture names"
assert_not_contains "$DS_STDOUT$DS_STDERR" "$unknown"
assert_contains "$DS_STDERR" "static command-names: 7 command names outside the allowed sets"
