# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# A checkout without a configured git identity commits as the owner of the instance, the author of
# its first commit, never as whoever made the last commit on the remote. The rule is the one of
# every instance commit of the framework (host, capture, upgrade, apply).
# shellcheck source=tests/apply/helpers.sh
source "$DS_REPO_ROOT/tests/apply/helpers.sh"

owner=$(git -C "$up_inst" log -1 --format='%an <%ae>' "$(git -C "$up_inst" rev-list --max-parents=0 HEAD)")
printf '' >"$GIT_CONFIG_GLOBAL"
git -C "$up_inst" config --unset user.name 2>/dev/null || true
git -C "$up_inst" config --unset user.email 2>/dev/null || true

clone=$DS_TEST_ROOT/other-person
git clone -q "$up_bare" "$clone"
printf 'theirs\n' >>"$clone/docs/guide.md"
git -C "$clone" -c user.name="Other Person" -c user.email=other@example.invalid commit -qam "docs: from someone else"
git -C "$clone" push -q origin HEAD:main

assert_exit 0 begin
edit "mine"
assert_exit 0 apply -m "docs: mine" --activate --publish
assert_eq "$owner" "$(git -C "$up_inst" log -1 --format='%an <%ae>')"
assert_eq "$owner" "$(git -C "$up_inst" log -1 --format='%cn <%ce>')"
assert_eq "$(head_oid)" "$(remote_oid)"
