# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# `dotsteward add` commits only its own change. What else waits between the remote and the work
# tree (a change of another file, a commit the remote lacks) is a question of maintain begin, so add
# writes nothing and exits 3 with it. What an earlier add of the same component left (a red gate,
# no network) is its own: the same command finishes it. Without a network add commits and the push
# waits (exit 6); on a machine that is not the producer the intent is free to write.
# shellcheck source=tests/track/helpers.sh
source "$DS_REPO_ROOT/tests/track/helpers.sh"

# Another change in the checkout: a question, nothing written.
edit "a change of something else"
head=$(head_oid)
assert_exit 3 add example-viewer --publish --json
assert_stdout_json '[.ask[].code] == ["checkout-dirty"] and .ask[0].changes == [" M docs/guide.md"]'
assert_eq "$head" "$(head_oid)" "no commit"
assert_eq " M docs/guide.md" "$(git -C "$up_inst" status --porcelain)" "only the other change is there"
toml_at work '.components["example-viewer"] == null'
git -C "$up_inst" checkout -q -- docs/guide.md

# A commit the remote lacks: a question too.
edit "an unpublished change"
git -C "$up_inst" commit -q -am "docs: an unpublished change"
assert_exit 3 add example-viewer --publish
assert_contains "$DS_STDOUT" "unpublished-commits"
toml_at work '.components["example-viewer"] == null'
git -C "$up_inst" reset -q --hard "$head"

# A red gate commits nothing and leaves the intent written; the same add finishes it.
touch "$UP_CONTROL/static-red"
assert_exit 1 add example-viewer --publish
assert_eq "$head" "$(head_oid)" "no commit"
toml_at work '.components["example-viewer"].enable == true'
rm -f -- "$UP_CONTROL/static-red"
clear_log
assert_exit 0 add example-viewer --publish
assert_order '^static '
assert_eq "feat: track example-viewer" "$(git -C "$up_inst" log -1 --format=%s)"
assert_eq "$(head_oid)" "$(remote_oid)" "published"

# No network: the commit is made, the push waits (exit 6); the same add with the network
# publishes it, and the commit of the earlier run is no question.
touch "$UP_CONTROL/network-down"
assert_exit 6 add example-notes --nix hello --publish
assert_eq "feat: track example-notes" "$(git -C "$up_inst" log -1 --format=%s)"
assert_eq "$(git -C "$up_inst" rev-parse HEAD^)" "$(remote_oid)" "the push waits"
rm -f -- "$UP_CONTROL/network-down"
assert_exit 0 add example-notes --nix hello --publish
assert_eq "$(head_oid)" "$(remote_oid)" "published"
assert_eq "feat: track example-notes" "$(git -C "$up_inst" log -1 --format=%s)" "no second commit"

# A machine that is not the producer writes the intent, a component of the catalog included.
set_toml hosts producer '"other-host"'
git -C "$up_inst" commit -q -am "chore: other-host is the producer"
git -C "$up_inst" push -q origin HEAD:main
assert_exit 0 remove example-viewer --publish
toml_at HEAD '.components["example-viewer"] == null'
assert_exit 0 add example-viewer --publish
toml_at HEAD '.components["example-viewer"] == {enable: true}'
assert_eq "$(head_oid)" "$(remote_oid)" "published"
