# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Every commit that leaves through `update publish` names the machine it comes from, whoever
# wrote it (an agent with a plain `git commit`, the writer of `upgrade`), because another machine
# asks about it by that name. The tree the gate proved does not change, the authors and dates
# stay, and a machine without a name adds nothing.
# shellcheck source=tests/cli/update/helpers.sh
source "$DS_REPO_ROOT/tests/cli/update/helpers.sh"

ds_use_stubs nix curl gh
serve_cache
export DOTSTEWARD_MACHINE=laptop1

base=$(head_oid)
change_and_commit "docs: first"
GIT_AUTHOR_NAME=somebody GIT_AUTHOR_EMAIL=somebody@example.invalid GIT_AUTHOR_DATE='2001-02-03T04:05:06Z' \
  change_and_commit "fix(docs): second"
git -C "$up_inst" commit -q --amend -m $'fix(docs): second\n\nA body that stays.' --no-edit --date='2001-02-03T04:05:06Z'
tree=$(head_tree)
write_validation
assert_exit 0 run_update publish --scope maintain --expected-base "$base"
head=$(head_oid)
assert_eq "$head" "$(remote_oid)" "HEAD is what was published"
assert_eq "$tree" "$(head_tree)" "the proved tree"
assert_contains "$DS_STDOUT" "published $head to main"
for commit in "$head" "$head^"; do
  assert_contains "$(git -C "$up_inst" log -1 --format=%B "$commit")" 'Dotsteward-Machine: laptop1'
done
assert_contains "$(git -C "$up_inst" log -1 --format=%B "$head")" 'A body that stays.'
assert_eq 'fix(docs): second' "$(git -C "$up_inst" log -1 --format=%s "$head")"
assert_eq 'somebody 981173106' "$(git -C "$up_inst" log -1 --format='%an %at' "$head")"
assert_eq "$base" "$(git -C "$up_inst" rev-parse "$head~2")"
[[ -z $(git -C "$up_inst" status --porcelain) ]] || ds_fail "the checkout is not clean"

# A commit that already names a machine keeps its name and its id.
git -C "$up_inst" commit -q --allow-empty -m $'docs: named\n\nDotsteward-Machine: laptop9'
named=$(head_oid)
write_validation
assert_exit 0 run_update publish --scope maintain
assert_eq "$named" "$(remote_oid)"

# Nothing to push: nothing is rewritten.
assert_exit 0 run_update publish --scope maintain --expected-base "$(git -C "$up_inst" rev-parse "$named^")"
assert_eq "$named" "$(head_oid)"

# Refused before the push: the commits stay as they are.
change_and_commit "not a conventional subject"
unconventional=$(head_oid)
write_validation
assert_exit 1 run_update publish --scope maintain
assert_eq "$unconventional" "$(head_oid)"
git -C "$up_inst" reset -q --hard "$named"

# A checkout that signs its commits: what gets the name is signed again.
cat >"$DS_TEST_ROOT/fake-gpg" <<'GPG'
#!/bin/sh
cat >/dev/null
printf '\n[GNUPG:] SIG_CREATED D 1 8 00 0 0\n' >&2
printf -- '-----BEGIN PGP SIGNATURE-----\n\nZmFrZQ==\n-----END PGP SIGNATURE-----\n'
GPG
chmod 0755 "$DS_TEST_ROOT/fake-gpg"
git -C "$up_inst" config gpg.program "$DS_TEST_ROOT/fake-gpg"
git -C "$up_inst" config commit.gpgsign true
change_and_commit "docs: signed"
write_validation
assert_exit 0 run_update publish --scope maintain
assert_contains "$(git -C "$up_inst" cat-file commit HEAD)" 'gpgsig -----BEGIN PGP SIGNATURE-----'
assert_contains "$(git -C "$up_inst" log -1 --format=%B)" 'Dotsteward-Machine: laptop1'
git -C "$up_inst" config --unset commit.gpgsign

# No name: nothing to say.
unset DOTSTEWARD_MACHINE
change_and_commit "docs: without a name"
nameless=$(head_oid)
write_validation
assert_exit 0 run_update publish --scope maintain
assert_eq "$nameless" "$(remote_oid)"
assert_not_contains "$(git -C "$up_inst" log -1 --format=%B)" 'Dotsteward-Machine'
