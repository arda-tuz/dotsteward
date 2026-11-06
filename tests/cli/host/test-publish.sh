# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # server hooks are single-quoted on purpose
# `dotsteward host publish`: hosts/<name>.toml lands on the remote in one commit without
# force, and the checkout never moves, so a dirty checkout is no obstacle. A remote that
# moved means a commit on the new tip; no network means exit 6 and nothing lost, because
# the next run works it out again; a refusal says so. The other keys of the file stay.
# shellcheck source=tests/cli/host/helpers.sh
source "$DS_REPO_ROOT/tests/cli/host/helpers.sh"

remote_tip() {
  git -C "$e2e_bare" rev-parse refs/heads/main
}

remote_file() {
  git -C "$e2e_bare" show "refs/heads/main:hosts/$1.toml"
}

checkout_untouched() {
  assert_eq "$head" "$(git -C "$agents_inst" rev-parse HEAD)" "the checkout moved"
  [[ ! -e $agents_inst/hosts/laptop.toml ]] || ds_fail "publish wrote into the checkout"
  assert_eq "$status_before" "$(git -C "$agents_inst" status --porcelain --untracked-files=normal)" "the checkout changed"
}

head=$(git -C "$agents_inst" rev-parse HEAD)
status_before=''
bare_before=$(remote_tip)

# Without a name there is nothing to publish.
assert_exit 1 run_host publish
assert_contains "$DS_STDERR" "no name yet"
assert_eq "$bare_before" "$(remote_tip)"

assert_exit 0 run_host init --name laptop --tags nvidia,small --profile workstation

# No network: nothing lost, nothing written, and the status says wait.
assert_exit 6 env DS_FAKESSH_FAIL=1 "$agents_fw/cli/dotsteward" --instance "$agents_inst" host publish </dev/null
assert_contains "$DS_STDERR" "hosts/laptop.toml waits"
assert_eq "$bare_before" "$(remote_tip)"
checkout_untouched
assert_exit 0 run_e2e

# The next run lands it: one commit, whose parent is the old tip, by this machine.
assert_exit 0 run_host publish
assert_contains "$DS_STDOUT" "published hosts/laptop.toml"
tip=$(remote_tip)
assert_eq "$bare_before" "$(git -C "$e2e_bare" rev-parse "$tip^")" "not one commit on the old tip"
assert_eq "hosts/laptop.toml" "$(git -C "$e2e_bare" diff-tree --no-commit-id --name-only -r "$tip")"
assert_eq "chore(hosts): publish laptop" "$(git -C "$e2e_bare" log -1 --format=%s "$tip")"
assert_contains "$(git -C "$e2e_bare" log -1 --format=%B "$tip")" "Dotsteward-Machine: laptop"
assert_eq 'schema_version = 1
system = "x86_64-linux"
profile = "workstation"
platform = "ubuntu-24.04"
tags = ["nvidia", "small"]' "$(remote_file laptop)"
checkout_untouched

# The checkout is behind now, and that is no failure.
assert_exit 0 run_e2e
assert_contains "$DS_STDOUT" "behind origin main"

# Nothing changed: no commit. The fetch stays off the shared remote-tracking ref, whose
# lock fails a concurrent fetch.
other=$DS_TEST_ROOT/other-clone
git clone -q "$e2e_bare" "$other"
ds_git_commit "$other" elsewhere.txt "elsewhere" "docs: elsewhere"
git -C "$other" push -q origin main
tracking=$(git -C "$agents_inst" rev-parse refs/remotes/origin/main)
assert_exit 0 run_host publish
assert_contains "$DS_STDOUT" "nothing to publish"
tip=$(remote_tip)
assert_eq "docs: elsewhere" "$(git -C "$e2e_bare" log -1 --format=%s "$tip")"
assert_eq "$tracking" "$(git -C "$agents_inst" rev-parse refs/remotes/origin/main)" "the fetch moved the remote-tracking ref"

# A dirty checkout is no obstacle, and what it holds does not travel.
printf 'scratch\n' >"$agents_inst/scratch.txt"
printf '\n# edited\n' >>"$agents_inst/versions.lock.json"
status_before=$(git -C "$agents_inst" status --porcelain --untracked-files=normal)
assert_exit 0 run_host init --tags nvidia
assert_exit 0 run_host publish
assert_eq "$tip" "$(git -C "$e2e_bare" rev-parse "$(remote_tip)^")"
assert_eq "hosts/laptop.toml" "$(git -C "$e2e_bare" diff-tree --no-commit-id --name-only -r "$(remote_tip)")"
assert_contains "$(remote_file laptop)" 'tags = ["nvidia"]'
checkout_untouched
rm -- "$agents_inst/scratch.txt"
git -C "$agents_inst" checkout -q -- versions.lock.json
status_before=''

# The remote moved first: the commit goes on the new tip, without force.
git -C "$other" pull -q --ff-only origin main
ds_git_commit "$other" elsewhere2.txt "elsewhere" "docs: elsewhere again"
git -C "$other" push -q origin main
elsewhere=$(git -C "$other" rev-parse HEAD)
assert_exit 0 run_host init --tags small
assert_exit 0 run_host publish
assert_eq "$elsewhere" "$(git -C "$e2e_bare" rev-parse "$(remote_tip)^")"
git -C "$e2e_bare" merge-base --is-ancestor "$elsewhere" "$(remote_tip)" || ds_fail "the push lost a commit"

# Another machine pushes between the fetch and the push: a transport that does that once.
race=$DS_TEST_ROOT/race-ssh.sh
{
  printf '#!%s\n' "$BASH"
  printf 'if [[ $* == *git-receive-pack* && ! -e %q ]]; then\n' "$DS_TEST_ROOT/raced"
  printf '  : >%q\n' "$DS_TEST_ROOT/raced"
  printf '  git -C %q pull -q --ff-only origin main\n' "$other"
  printf '  printf "race\\n" >>%q\n' "$other/elsewhere.txt"
  printf '  git -C %q commit -qam "docs: the race"\n' "$other"
  printf '  git -C %q push -q origin main\n' "$other"
  printf 'fi\n'
  printf 'exec %q "$@"\n' "$GIT_SSH_COMMAND"
} >"$race"
chmod 0755 "$race"
git -C "$other" remote set-url origin "$e2e_bare"
assert_exit 0 run_host init --tags raced
assert_exit 0 env GIT_SSH_COMMAND="$race" "$agents_fw/cli/dotsteward" --instance "$agents_inst" host publish </dev/null
[[ -e $DS_TEST_ROOT/raced ]] || ds_fail "the race did not happen"
assert_eq "docs: the race" "$(git -C "$e2e_bare" log -1 --format=%s "$(remote_tip)^")"
assert_contains "$(remote_file laptop)" 'tags = ["raced"]'

# The other keys of the file stay, comments too, and a new platform counts.
clone=$DS_TEST_ROOT/edit-clone
git clone -q "$e2e_bare" "$clone"
cat >"$clone/hosts/laptop.toml" <<'TOML'
# This machine is the small one.
schema_version = 1
system = "x86_64-linux"
platform = "ubuntu-22.04"
tags = ["raced"]

[declined]
skills = ["example-skill"]

[holds.example]
version = "1.2.3"
reason = "the next one breaks"
since = "2026-01-02"

[apt.gated]
enable = false
TOML
git -C "$clone" add -A
git -C "$clone" commit -q -m "chore(hosts): edit laptop"
git -C "$clone" push -q origin main
assert_exit 0 run_host publish
assert_contains "$(remote_file laptop)" "# This machine is the small one."
assert_contains "$(remote_file laptop)" 'platform = "ubuntu-24.04"'
assert_contains "$(remote_file laptop)" 'profile = "workstation"'
assert_contains "$(remote_file laptop)" 'skills = ["example-skill"]'
assert_contains "$(remote_file laptop)" 'version = "1.2.3"'
assert_contains "$(remote_file laptop)" 'enable = false'

# A push of a commit whose answer is lost: the next fetch sees it, no second commit.
lost=$DS_TEST_ROOT/lost-ssh.sh
{
  printf '#!%s\n' "$BASH"
  printf 'if [[ $* == *git-receive-pack* && ! -e %q ]]; then\n' "$DS_TEST_ROOT/lost"
  printf '  : >%q\n' "$DS_TEST_ROOT/lost"
  printf '  %q "$@" || exit\n' "$GIT_SSH_COMMAND"
  printf '  exit 255\n'
  printf 'fi\n'
  printf 'exec %q "$@"\n' "$GIT_SSH_COMMAND"
} >"$lost"
chmod 0755 "$lost"
assert_exit 0 run_host init --tags lost
before_lost=$(remote_tip)
assert_exit 0 env GIT_SSH_COMMAND="$lost" "$agents_fw/cli/dotsteward" --instance "$agents_inst" host publish </dev/null
[[ -e $DS_TEST_ROOT/lost ]] || ds_fail "the lost answer did not happen"
assert_eq "$before_lost" "$(git -C "$e2e_bare" rev-parse "$(remote_tip)^")" "a second commit was made"

# The remote refuses: a refusal, not a wait.
hook=$e2e_bare/hooks/pre-receive
printf '#!%s\nprintf "not today\\n" >&2\nexit 1\n' "$BASH" >"$hook"
chmod 0755 "$hook"
assert_exit 0 run_host init --tags refused
assert_exit 1 run_host publish
assert_contains "$DS_STDERR" "the remote refused the push"
rm -- "$hook"

# A pre-push hook of this checkout refuses: the same.
mkdir -p "$DS_TEST_ROOT/hooks"
printf '#!%s\nprintf "the hook says no\\n" >&2\nexit 1\n' "$BASH" >"$DS_TEST_ROOT/hooks/pre-push"
chmod 0755 "$DS_TEST_ROOT/hooks/pre-push"
git -C "$agents_inst" config core.hooksPath "$DS_TEST_ROOT/hooks"
assert_exit 1 run_host publish
assert_contains "$DS_STDERR" "the push of hosts/laptop.toml failed"
assert_contains "$DS_STDERR" "the hook says no"
git -C "$agents_inst" config --unset core.hooksPath

# A git identity is not needed: the author of the tip, and no configuration is written.
assert_exit 0 env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" host publish </dev/null
assert_eq "$DS_TEST_IDENTITY_NAME" "$(git -C "$e2e_bare" log -1 --format=%an "$(remote_tip)")"
assert_eq "" "$(git -C "$agents_inst" config --local --get user.name || true)"

# A privacy finding: nothing is published, and the status says so.
denylist=$DS_TEST_ROOT/denylist.txt
printf 'denied-name\n' >"$denylist"
sed -i '/^\[skills\]/i [privacy]\ndenylist = "'"$denylist"'"\n' "$agents_inst/workstation.toml"
assert_exit 0 run_host init --tags denied-name
before_scan=$(remote_tip)
assert_exit 4 run_host publish
assert_contains "$DS_STDERR" "the privacy scan"
assert_not_contains "$DS_STDOUT$DS_STDERR" "tags = "
assert_eq "$before_scan" "$(remote_tip)"
