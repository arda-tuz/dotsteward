# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# bare-remote.sh builds local repositories and bare remotes; fakessh.sh is a
# GIT_SSH_COMMAND that maps SSH remote URLs to those bare repositories, so
# code keeps byte-identical origin URLs and still talks to a local remote.
# shellcheck source=tests/lib/bare-remote.sh
source "$DS_REPO_ROOT/tests/lib/bare-remote.sh"
# shellcheck source=tests/lib/fakessh.sh
source "$DS_REPO_ROOT/tests/lib/fakessh.sh"

# --- bare-remote.sh -------------------------------------------------------
ds_git_repo instance
assert_eq main "$(git -C instance symbolic-ref --short HEAD)"
assert_eq 1 "$(git -C instance rev-list --count HEAD)"
assert_eq "" "$(git -C instance status --porcelain)"
ds_git_commit instance docs/notes.md "first note" "docs: add notes"
assert_eq "first note" "$(<instance/docs/notes.md)"
assert_eq "docs: add notes" "$(git -C instance log -1 --format=%s)"

ds_bare_remote remote.git instance
assert_eq true "$(git --git-dir=remote.git rev-parse --is-bare-repository)"
assert_eq "$(git -C instance rev-parse HEAD)" "$(git --git-dir=remote.git rev-parse refs/heads/main)"
assert_eq refs/heads/main "$(git --git-dir=remote.git symbolic-ref HEAD)"
ds_bare_remote empty.git
assert_eq "" "$(git --git-dir=empty.git for-each-ref)"
assert_exit 1 ds_bare_remote remote.git
assert_contains "$DS_STDERR" "already exists"

# --- fakessh.sh -----------------------------------------------------------
url=git@github.com:example-org/example-instance.git
ds_fakessh_enable
assert_eq "$DS_REPO_ROOT/tests/lib/fakessh.sh" "$GIT_SSH_COMMAND"
ds_fakessh_map "$url" remote.git
ds_fakessh_map ssh://git@example.invalid:2222/srv/other.git empty.git

# clone, push and ls-remote over the fake transport; the URL stays intact.
git clone -q "$url" clone
assert_eq "$url" "$(git -C clone remote get-url origin)"
assert_eq "first note" "$(<clone/docs/notes.md)"
ds_git_commit clone docs/notes.md "second note" "docs: update notes"
git -C clone push -q origin main
assert_eq "$(git -C clone rev-parse HEAD)" "$(git --git-dir=remote.git rev-parse refs/heads/main)"
assert_eq "$(git -C clone rev-parse HEAD)	refs/heads/main" "$(git ls-remote "$url" refs/heads/main)"
git -C clone push -q ssh://git@example.invalid:2222/srv/other.git main
assert_eq "$(git -C clone rev-parse HEAD)" "$(git --git-dir=empty.git rev-parse refs/heads/main)"
log=$(<"$DS_FAKESSH_LOG")
assert_contains "$log" "git@github.com git-upload-pack example-org/example-instance.git"
assert_contains "$log" "git@github.com git-receive-pack example-org/example-instance.git"
assert_contains "$log" "git@example.invalid git-receive-pack srv/other.git"

# Unknown repositories fail like a missing GitHub repository.
assert_exit 128 git ls-remote git@github.com:example-org/missing.git
assert_contains "$DS_STDERR" "Repository not found"

# A slow or refused connection, for timeout and offline paths.
DS_FAKESSH_SLEEP=5 assert_exit 124 timeout 1 git ls-remote "$url"
DS_FAKESSH_FAIL=1 assert_exit 128 git ls-remote "$url"
assert_contains "$DS_STDERR" "Connection refused"

# git's OpenSSH detection (-G) succeeds, so ports and options work; any
# command other than the git transport commands is refused.
assert_exit 0 "$DS_REPO_ROOT/tests/lib/fakessh.sh" -G github.com
assert_exit 1 "$DS_REPO_ROOT/tests/lib/fakessh.sh" github.com "rm -rf /"
assert_contains "$DS_STDERR" "unsupported command"
