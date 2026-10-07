# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# shellcheck disable=SC2016 # fixture text with a literal $ is written on purpose
# Framework mode: the framework source under test passes every framework
# contract in the sandbox context (no .git, find-listed files), and each
# generic contract fails on a copy of the source with one defect.
# shellcheck source=tests/static/helpers.sh
source "$DS_REPO_ROOT/tests/static/helpers.sh"

command -v shellcheck >/dev/null 2>&1 || ds_fail "the static tests need shellcheck on PATH"

# The real tree, every framework check, sandbox context.
cd "$DS_REPO_ROOT"
assert_exit 0 static --sandbox
assert_contains "$DS_STDOUT" "[dotsteward] static checks passed (framework): shell bans command-names seeds privacy"
assert_contains "$DS_STDOUT" "scan clean:"

fw=$DS_TEST_ROOT/fw
framework_copy "$fw"

# shell: a parse error, a missing exec bit, a file that is neither a script
# nor a declared library, and a ShellCheck finding are all reported.
mkdir -p "$fw/tools"
printf '#!/usr/bin/env bash\nif then\n' >"$fw/tools/broken.sh"
chmod 0755 "$fw/tools/broken.sh"
printf '#!/usr/bin/env bash\nprintf ok\n' >"$fw/tools/not-exec.sh"
chmod 0644 "$fw/tools/not-exec.sh"
printf 'printf ok\n' >"$fw/tools/undeclared.sh"
printf '#!/usr/bin/env bash\nfiles=$(ls)\necho $files\n' >"$fw/tools/lint.sh"
chmod 0755 "$fw/tools/lint.sh"
assert_exit 1 fw_static "$fw" --sandbox --only shell
assert_contains "$DS_STDERR" "[dotsteward] ERROR: static shell: tools/broken.sh: bash -n failed"
assert_contains "$DS_STDERR" "static shell: tools/not-exec.sh: has a shebang but is not executable"
assert_contains "$DS_STDERR" "static shell: tools/undeclared.sh: has neither a shebang nor a '# shellcheck shell=' directive"
assert_contains "$DS_STDERR" "static shell: shellcheck reported findings"
assert_contains "$DS_STDOUT$DS_STDERR" "SC2086"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: static checks failed (framework): shell"
rm -f "$fw"/tools/*.sh

# bans: production code only; tests may exercise banned flags.
printf '#!/usr/bin/env bash\n%s -fsSL https://example.invalid/install | sh\n' "$BAN_FETCH" >"$fw/tools/a.sh"
printf '#!/usr/bin/env bash\n%s origin main %s\n' "$BAN_PUSH" "$BAN_FORCE" >"$fw/tools/b.sh"
printf '{ ... }: "apt-get install %s example-app"\n' "$BAN_DOWNGRADE" >"$fw/tools/c.nix"
mkdir -p "$fw/tests/extra"
printf '#!/usr/bin/env bash\napt-get install %s example-app\n' "$BAN_DOWNGRADE" >"$fw/tests/extra/ok.sh"
chmod 0755 "$fw"/tools/*.sh "$fw/tests/extra/ok.sh"
assert_exit 1 fw_static "$fw" --sandbox --only bans
assert_contains "$DS_STDERR" "static bans: tools/a.sh:2: a download piped into a shell"
assert_contains "$DS_STDERR" "static bans: tools/b.sh:2: a forced git push"
assert_contains "$DS_STDERR" "static bans: tools/c.nix:1: a package downgrade flag"
assert_not_contains "$DS_STDERR" "tests/extra/ok.sh"
# The ban patterns in the command itself are exempt.
assert_not_contains "$DS_STDERR" "cli/commands/static.sh"
rm -rf "$fw/tools" "$fw/tests/extra"
assert_exit 0 fw_static "$fw" --sandbox --only bans

# privacy: the framework policy (generic rules including non-ASCII text and
# forbidden paths) over the whole tree.
printf 'token %s\n' "$(fake_secret ghp_ 36)" >"$fw/notes.txt"
printf 'caf\xc3\xa9\n' >"$fw/word.txt"
mkdir -p "$fw/notes"
printf '{}\n' >"$fw/notes/app.local.json"
assert_exit 1 fw_static "$fw" --sandbox --only privacy
assert_contains "$DS_STDOUT" "secret-github-token notes.txt:1"
assert_contains "$DS_STDOUT" "non-ascii word.txt:1"
assert_contains "$DS_STDOUT" "forbidden-path notes/app.local.json (path)"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: static privacy: the scan found 3 findings"
# Redacted: the secret itself is never printed.
assert_not_contains "$DS_STDOUT$DS_STDERR" "ghp_"

# Git context: only files git would carry are scanned (ignored ones are not).
fwgit=$DS_TEST_ROOT/fwgit
framework_copy "$fwgit"
git init -q "$fwgit"
git -C "$fwgit" add -A
git -C "$fwgit" commit -q -m "test: framework copy"
printf 'token %s\n' "$(fake_secret ghp_ 36)" >"$fwgit/result-notes"
assert_exit 0 fw_static "$fwgit" --only privacy
assert_exit 1 fw_static "$fwgit" --sandbox --only privacy
assert_contains "$DS_STDOUT" "secret-github-token result-notes:1"
