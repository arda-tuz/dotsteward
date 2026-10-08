# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# Repository checks of `dotsteward e2e` against a bare
# remote reached through the instance's own SSH URL: the checkout is a clean
# git work tree (core:repo-clean), origin equals instance.remote
# (core:repo-origin), the remote branch is read with git_net (time-limited,
# batch-mode SSH) and equals the local HEAD, or, with
# --expected-remote-base OID before a publish, equals OID while OID is an
# ancestor of HEAD (core:repo-remote), and the vendored SKILL.md files git
# tracks match expected_skill_count of the instance skills lock
# (core:repo-skill-count).
# shellcheck source=tests/cli/e2e/helpers.sh
source "$DS_REPO_ROOT/tests/cli/e2e/helpers.sh"

repo_findings() {
  jq -c '[.findings[] | select(.step | startswith("core:repo")) | [.step, .code]]' <<<"$DS_STDOUT"
}

# One vendored skill, installed, committed and published.
lock_add alpha
assert_exit 0 run_agents install
publish_instance
assert_exit 0 run_e2e
base=$(git -C "$agents_inst" rev-parse HEAD)

# A dirty checkout: untracked, then modified files.
printf 'scratch\n' >"$agents_inst/scratch.txt"
assert_exit 1 run_e2e --json
assert_eq "$(jq -cn --arg inst "$agents_inst" '[["core:repo-clean", "repo-dirty", $inst]]')" "$(findings)"
assert_json - '.findings[0].message | startswith("instance checkout is not clean")' <<<"$DS_STDOUT"
rm "$agents_inst/scratch.txt"
printf '# changed\n' >>"$agents_inst/versions.lock.json"
assert_exit 1 run_e2e
assert_contains "$DS_STDERR" "instance checkout is not clean"
git -C "$agents_inst" checkout -q -- versions.lock.json

# origin must be the configured remote, byte for byte.
other_url='git@github.com:example-org/other.git'
ds_fakessh_map "$other_url" "$e2e_bare"
git -C "$agents_inst" remote set-url origin "$other_url"
assert_exit 1 run_e2e --json --keep-going
assert_eq '[["core:repo-origin","repo-origin-mismatch"]]' "$(repo_findings)"
assert_json - '.findings[0].message == "origin of the instance checkout is git@github.com:example-org/other.git, expected git@github.com:example-org/workstation.git (instance.remote)"' <<<"$DS_STDOUT"
git -C "$agents_inst" remote set-url origin "$e2e_remote_url"

# A local commit that is not published: the local and remote branches
# differ, unless the pre-publish base is given.
ds_git_commit "$agents_inst" notes.txt "local work" "docs: local work"
head=$(git -C "$agents_inst" rev-parse HEAD)
assert_exit 1 run_e2e --json
assert_eq '[["core:repo-remote","remote-mismatch"]]' "$(repo_findings)"
assert_contains "$DS_STDOUT" "local HEAD $head differs from origin main $base"
assert_exit 0 run_e2e --expected-remote-base "$base"
assert_contains "$DS_STDOUT" "[dotsteward] e2e checks passed (profile workstation)"

# The remote moved after the base was recorded.
other=$DS_TEST_ROOT/other-clone
git clone -q "$e2e_bare" "$other"
ds_git_commit "$other" elsewhere.txt "elsewhere" "docs: elsewhere"
git -C "$other" push -q origin main
moved=$(git -C "$other" rev-parse HEAD)
assert_exit 1 run_e2e --expected-remote-base "$base" --json
assert_eq '[["core:repo-remote","remote-base-moved"]]' "$(repo_findings)"
assert_contains "$DS_STDOUT" "origin main is $moved, not the expected publish base $base"

# The base must be an ancestor of HEAD.
assert_exit 1 run_e2e --expected-remote-base "$moved" --json
assert_eq '[["core:repo-remote","base-not-ancestor"]]' "$(repo_findings)"
assert_contains "$DS_STDOUT" "the expected publish base $moved is not an ancestor of HEAD $head"
git -C "$agents_inst" pull -q --rebase origin main
publish_instance
assert_exit 0 run_e2e

# An unreachable remote: one finding, the time limit and batch mode apply.
assert_exit 1 env DS_FAKESSH_FAIL=1 "$agents_fw/cli/dotsteward" --instance "$agents_inst" e2e \
  --profile workstation --json
assert_eq '[["core:repo-remote","remote-unreachable"]]' "$(repo_findings)"
assert_contains "$DS_STDOUT" "cannot read origin main of the instance checkout"

# The vendored skill count must match the lock.
printf 'agent/skills/alpha/SKILL.md\n' >"$agents_inst/.gitignore"
git -C "$agents_inst" rm -q --cached agent/skills/alpha/SKILL.md
publish_instance
assert_exit 1 run_e2e --json
assert_eq '[["core:repo-skill-count","skill-count-mismatch"]]' "$(repo_findings)"
assert_contains "$DS_STDOUT" "git tracks 0 vendored skills (agent/skills/*/SKILL.md), the skills lock expects 1"
git -C "$agents_inst" rm -q --cached .gitignore
rm "$agents_inst/.gitignore"
git -C "$agents_inst" add agent/skills/alpha/SKILL.md
publish_instance
assert_exit 0 run_e2e

# Not a git work tree: one finding, the other repository checks are
# skipped; --skip-repo-checks skips them all.
mv "$agents_inst/.git" "$DS_TEST_ROOT/instance.git"
assert_exit 1 run_e2e --json --keep-going
assert_eq '[["core:repo-clean","repo-not-git"]]' "$(repo_findings)"
assert_exit 0 run_e2e --skip-repo-checks
mv "$DS_TEST_ROOT/instance.git" "$agents_inst/.git"
assert_exit 0 run_e2e
assert_eq "" "$(temp_dirs)"
