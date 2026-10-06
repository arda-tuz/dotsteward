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

# A copy-deployed lock skill whose canonical entry is a dangling managed link
# (the legacy copy it pointed to is gone): the skill is not found, so install
# removes the link and installs the skill in its place in the same run (the
# sweep runs only after the skills). check reports the missing skill until
# then. A dangling link to a foreign target at the destination is refused.
lock_add alpha
ln -s ../../.codex/skills/alpha "$canonical/alpha"
ln -s ../../.agents/skills/alpha "$claude/alpha"
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "skill missing: alpha"
assert_symlink_to "$canonical/alpha" ../../.codex/skills/alpha
assert_exit 0 run_agents install
assert_contains "$DS_STDOUT" "removed dangling skill link: $canonical/alpha"
assert_contains "$DS_STDOUT" "installed skill alpha into $canonical/alpha"
[[ -d $canonical/alpha && ! -L $canonical/alpha ]] || ds_fail "alpha is a physical copy"
[[ ! -e $HOME/.codex/skills/alpha ]] || ds_fail "nothing is written through the dangling link"
assert_eq "$(bash -c 'source "$1/cli/lib/lib.sh"; directory_sha256 "$2"' _ "$DS_REPO_ROOT" "$canonical/alpha")" \
  "$(jq -r '.skills[] | select(.name == "alpha") | .directory_sha256' "$agents_lock")"
assert_symlink_to "$claude/alpha" ../../.agents/skills/alpha
assert_exit 0 run_agents check

# The same with the link in its absolute form ($HOME/<legacy root>/...).
rm -rf -- "$canonical/alpha"
ln -s "$HOME/.codex/skills/alpha" "$canonical/alpha"
assert_exit 0 run_agents install
assert_contains "$DS_STDOUT" "removed dangling skill link: $canonical/alpha"
[[ -d $canonical/alpha && ! -L $canonical/alpha ]] || ds_fail "alpha is a physical copy again"
assert_exit 0 run_agents check

# Refused: a dangling link to a foreign target, a live link and a real
# directory are never replaced.
lock_add foreign
assert_exit 1 run_agents install
assert_contains "$DS_STDERR" "skill install destination exists: $canonical/foreign"
assert_symlink_to "$canonical/foreign" "$DS_TEST_ROOT/elsewhere/gone"
assert_exit 1 run_agents install
assert_contains "$DS_STDERR" "skill install destination exists: $canonical/foreign"
