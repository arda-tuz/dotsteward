# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# T1: the framework static contracts pass on a complete instance in both
# contexts: the git working tree (files git would carry) and the sandbox
# (no .git, every file found below the root).
# shellcheck source=tests/static/helpers.sh
source "$DS_REPO_ROOT/tests/static/helpers.sh"

command -v shellcheck >/dev/null 2>&1 || ds_fail "the static tests need shellcheck on PATH"

inst=$DS_TEST_ROOT/inst
make_instance "$inst"
all="shell bans launcher bootstrap skills versions-lock allowlist protected overlays privacy scripts"

cd "$inst"
assert_exit 0 static
assert_contains "$DS_STDOUT" "[dotsteward] static checks passed (instance): $all"
assert_contains "$DS_STDOUT" "scan clean:"
assert_eq "" "$DS_STDERR"

# The sandbox context: a copy without .git, the way a Nix check sees it.
sandbox=$DS_TEST_ROOT/sandbox
copy_tree "$inst" "$sandbox"
cd "$sandbox"
assert_exit 0 static --sandbox
assert_contains "$DS_STDOUT" "[dotsteward] static checks passed (instance): $all"
# Without git, the default context is the sandbox's: every file is listed.
assert_exit 0 static
cd "$inst"

# Content that the instance policy accepts although the framework policy
# would not: non-ASCII text, home paths, e-mail addresses, private IPv4
# addresses (owner content is personal by design).
printf 'caf\xc3\xa9 /home/%s/x %s@%s 192.168.%s.%s\n' someone someone example.net 0 7 >"$inst/home/notes.txt"
commit_instance "$inst"
assert_exit 0 static --only privacy

# An ignored file is not scanned in the git context, but is in the sandbox
# context.
printf 'key %s\n' "$(fake_secret ghp_ 36)" >"$inst/debug.log"
assert_exit 0 static --only privacy
assert_exit 1 static --sandbox --only privacy
assert_contains "$DS_STDOUT" "secret-github-token debug.log:1"
rm -f "$inst/debug.log"

# Generated and vendored content is not linted: vendored skills keep their
# upstream shell style; a .sh file there is neither parsed nor checked.
printf 'if then\n' >"$inst/agent/skills/example-skill/references/upstream.sh"
write_skill_lock "$inst"
commit_instance "$inst"
assert_exit 0 static --only shell,bans,skills
