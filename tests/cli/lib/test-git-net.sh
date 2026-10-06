# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# git_net SECONDS ARG...: git with a batch-mode SSH command (unless
# GIT_SSH_COMMAND is set), no terminal prompts and a time limit (status 124).
# shellcheck source=tests/cli/lib/helpers.sh
source "$DS_REPO_ROOT/tests/cli/lib/helpers.sh"
# shellcheck source=tests/lib/bare-remote.sh
source "$DS_REPO_ROOT/tests/lib/bare-remote.sh"
# shellcheck source=tests/lib/fakessh.sh
source "$DS_REPO_ROOT/tests/lib/fakessh.sh"

# A recording git in front of the real one.
bin=$DS_TEST_ROOT/fake-bin
mkdir -p "$bin"
cat >"$bin/git" <<SH
#!$BASH
printf '%s|%s|%s\n' "\${GIT_SSH_COMMAND-unset}" "\${GIT_TERMINAL_PROMPT-unset}" "\$*" >>"$DS_TEST_ROOT/git.log"
if [[ \${1:-} == sleep ]]; then sleep "\$2"; fi
exit "\${FAKE_GIT_STATUS:-0}"
SH
chmod 0755 "$bin/git"
with_fake_git() { PATH=$bin:$PATH "$@"; }

with_fake_git git_net 5 ls-remote git@github.com:example/repo.git
assert_eq "ssh -o BatchMode=yes -o ConnectTimeout=15|0|ls-remote git@github.com:example/repo.git" \
  "$(<"$DS_TEST_ROOT/git.log")"
: >"$DS_TEST_ROOT/git.log"
GIT_SSH_COMMAND="ssh -i key" with_fake_git git_net 5 fetch origin
assert_eq "ssh -i key|0|fetch origin" "$(<"$DS_TEST_ROOT/git.log")"
# git's status propagates; the time limit gives 124.
fail_git() { FAKE_GIT_STATUS=128 with_fake_git git_net 5 fetch; }
assert_exit 128 fail_git
assert_exit 124 with_fake_git git_net 1 sleep 5
# An argument that looks like an option is passed through untouched.
: >"$DS_TEST_ROOT/git.log"
with_fake_git git_net 5 -C "$DS_TEST_ROOT/a dir" status
assert_eq "ssh -o BatchMode=yes -o ConnectTimeout=15|0|-C $DS_TEST_ROOT/a dir status" "$(<"$DS_TEST_ROOT/git.log")"

# End to end with the real git over the fake SSH transport.
ds_git_repo "$DS_TEST_ROOT/repo"
ds_bare_remote "$DS_TEST_ROOT/remote.git" "$DS_TEST_ROOT/repo"
ds_fakessh_enable
ds_fakessh_map git@github.com:example/workstation.git "$DS_TEST_ROOT/remote.git"
head=$(git -C "$DS_TEST_ROOT/repo" rev-parse HEAD)
assert_exit 0 git_net 20 ls-remote git@github.com:example/workstation.git refs/heads/main
assert_eq "$head"$'\t'"refs/heads/main" "$DS_STDOUT"
assert_contains "$(<"$DS_FAKESSH_LOG")" "git@github.com git-upload-pack"
assert_exit 128 git_net 20 ls-remote git@github.com:example/missing.git
slow() { DS_FAKESSH_SLEEP=5 git_net 1 ls-remote git@github.com:example/workstation.git; }
assert_exit 124 slow
