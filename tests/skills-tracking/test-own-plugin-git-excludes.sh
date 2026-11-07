# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and plugin-helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# An own plugin that is a git repository of the user (review-c2 C2-M3): what git ignores
# there, by .git/info/exclude or by the global excludes file of the user, is private and
# never reaches the repository of the instance, like what its .gitignore ignores; skills
# status names it as left out.
# shellcheck source=tests/skills-tracking/plugin-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/plugin-helpers.sh"

new_machine a
priv=$(plugin_dir a priv)
new_plugin a priv
git init -q -b main "$priv"
printf 'node_modules/\n' >"$priv/.gitignore"
mkdir -p "$priv/node_modules"
printf 'x\n' >"$priv/node_modules/lib.js"
printf 'excluded-by-info.txt\n' >>"$priv/.git/info/exclude"
printf 'excluded-by-global.txt\n' >"$DS_TEST_ROOT/global-ignore"
git config --file "$GIT_CONFIG_GLOBAL" core.excludesFile "$DS_TEST_ROOT/global-ignore"
for file in excluded-by-info.txt excluded-by-global.txt NOTES.local; do
  printf 'private\n' >"$priv/$file"
done
git -C "$priv" add .claude-plugin skills .gitignore
git -C "$priv" commit -q -m "chore: a plugin"
# git itself ignores the two.
[[ $(git -C "$priv" status --porcelain --ignored -- excluded-by-info.txt excluded-by-global.txt | grep -c '^!!') == 2 ]] ||
  ds_fail "the fixture: git ignores both files"
settle_plugin a priv
assert_exit 0 ds a skills reconcile
assert_eq ask "$(plugin_item a priv .state)"
ds_code a skills track priv --all --own
for file in excluded-by-info.txt excluded-by-global.txt node_modules/lib.js; do
  if git -C "$remote" cat-file -e "refs/heads/main:agent/plugins/priv/$file" 2>/dev/null; then
    ds_fail "$file is ignored by the repository of the plugin and stays out"
  fi
done
git -C "$remote" cat-file -e refs/heads/main:agent/plugins/priv/NOTES.local 2>/dev/null ||
  ds_fail "a file git does not ignore goes"
git -C "$remote" cat-file -e refs/heads/main:agent/plugins/priv/.claude-plugin/plugin.json 2>/dev/null ||
  ds_fail "the plugin goes"
assert_exit 0 ds a skills status
assert_contains "$DS_STDOUT" "priv: left out by an ignore rule: excluded-by-info.txt"
assert_contains "$DS_STDOUT" "priv: left out by an ignore rule: excluded-by-global.txt"
# Seen again: in sync, the left-out files are no change.
git -C "$(clone_of a)" pull -q --ff-only
assert_exit 0 ds a skills reconcile --full
assert_eq "{}" "$(plugin_item a priv .)"
assert_exit 0 ds a agents check --profile workstation
