# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# The command line: 0 done, 1 refusal, 2 usage, 3 questions wait.
# shellcheck source=tests/incoming/helpers.sh
source "$DS_REPO_ROOT/tests/incoming/helpers.sh"

machine_up laptop1
machine_up laptop2

assert_exit 0 ds laptop2 incoming --help
assert_contains "$DS_STDOUT" 'Exit status'
assert_exit 2 ds laptop2 incoming nonsense
assert_exit 2 ds laptop2 incoming answer skill:foo
assert_exit 2 ds laptop2 incoming answer skill:foo --install --never
assert_exit 1 ds laptop2 incoming show skill:nothing
assert_exit 1 ds laptop2 incoming answer skill:nothing --install
assert_exit 0 ds laptop2 incoming list
assert_contains "$DS_STDOUT" 'nothing waits'

# Without a remote that answers it says so and goes on with the checkout it has.
captured laptop1 foo
url=$(git -C "$(clone_of laptop2)" remote get-url origin)
git -C "$(clone_of laptop2)" remote set-url origin "$world/gone.git"
assert_exit 0 ds laptop2 incoming
assert_contains "$DS_STDERR" 'no network'
git -C "$(clone_of laptop2)" remote set-url origin "$url"

# A dirty checkout stays where it is, and says why.
printf '\n' >>"$(clone_of laptop2)/workstation.toml"
assert_exit 0 ds laptop2 incoming
assert_contains "$DS_STDERR" 'uncommitted'
git -C "$(clone_of laptop2)" checkout -q -- workstation.toml

# The next look moves on and asks.
EXPECT_STATUS=3 ds_code laptop2 incoming --json
assert_json - '.items[0].id == "skill:foo"' <<<"$DS_STDOUT"
assert_contains "$DS_STDOUT" '"skill:foo"'
