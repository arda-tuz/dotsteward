# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# The dangling-link sweep (SPEC 8.1; understanding report I-S3, test 10):
# directly in the canonical root and in every link root, a dangling link
# whose literal target is inside a managed root (relative ../../<root>/...
# or $HOME/<root>/... for the canonical and legacy roots) is removed and
# logged; foreign dangling links, live links and real directories stay.
# check fails on the first one; with --keep-going it reports each.
# shellcheck source=tests/agents/helpers.sh
source "$DS_REPO_ROOT/tests/agents/helpers.sh"

mkdir -p "$HOME/.agents/skills" "$HOME/.codex/skills" "$HOME/.claude/skills" "$DS_TEST_ROOT/live"
canonical=$HOME/.agents/skills
claude=$HOME/.claude/skills
ln -s ../../.codex/skills/gone-a "$canonical/gone-a"
ln -s "$HOME/.codex/skills/gone-b" "$canonical/gone-b"
ln -s ../../.agents/skills/gone-c "$claude/gone-c"
ln -s "$HOME/.agents/skills/gone-d" "$claude/gone-d"
# Kept: foreign dangling links, live links, real directories, nested links.
ln -s "$DS_TEST_ROOT/elsewhere/gone" "$canonical/foreign"
ln -s ../../.config/gone "$claude/foreign-relative"
ln -s "$DS_TEST_ROOT/live" "$canonical/live"
mkdir "$canonical/real" "$canonical/real/nested"
ln -s ../../.codex/skills/gone-e "$canonical/real/nested/gone-e"

before=$(home_state)
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "dangling skill link not removed: $canonical/gone-a"
assert_not_contains "$DS_STDERR" "gone-b"
assert_eq "$before" "$(home_state)"

assert_exit 1 run_agents check --keep-going --json
assert_json - '.result == "failed"
  and ([.findings[] | select(.step == "sweep" and .code == "dangling-link") | .path]
    == [$ENV.HOME + "/.agents/skills/gone-a", $ENV.HOME + "/.agents/skills/gone-b",
        $ENV.HOME + "/.claude/skills/gone-c", $ENV.HOME + "/.claude/skills/gone-d"])' <<<"$DS_STDOUT"

assert_exit 0 run_agents install
for link in "$canonical/gone-a" "$canonical/gone-b" "$claude/gone-c" "$claude/gone-d"; do
  assert_contains "$DS_STDOUT" "removed dangling skill link: $link"
  [[ ! -e $link && ! -L $link ]] || ds_fail "$link is removed"
done
for link in "$canonical/foreign" "$claude/foreign-relative" "$canonical/live" "$canonical/real/nested/gone-e"; do
  [[ -L $link ]] || ds_fail "$link is kept"
done
[[ -d $canonical/real ]] || ds_fail "real directories are kept"
assert_exit 0 run_agents check
