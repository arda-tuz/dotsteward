# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and plugin-helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# skills track --all about a plugin of a marketplace, ended while generate evaluates (review-c2
# C2-M2, C2-m2): nothing is published, the evaluation it started ends with it, and the answer
# stays visible: skills status names it with the command, the session says it once it has
# waited, and skills retry publishes it in one commit.
# shellcheck source=tests/skills-tracking/plugin-helpers.sh
source "$DS_REPO_ROOT/tests/skills-tracking/plugin-helpers.sh"

git clone -q "$remote" "$world/edit"
printf '\n[components.claude-code]\nenable = true\n' >>"$world/edit/workstation.toml"
commit_instance "$world/edit"
git -C "$world/edit" push -q origin HEAD:main

new_machine a
fake_nix_mirrors a
nixbin=$(home_of a)/.nix-profile/bin/nix
# While nix-hang exists, the evaluation writes its process id and hangs.
sed -i "2i [[ -e $DS_TEST_ROOT/nix-hang ]] && { printf '%s\\\\n' \$\$ >$DS_TEST_ROOT/nix-pid; exec sleep 120; }" "$nixbin"
dir=$(home_of a)/.claude/plugins
mkdir -p "$dir"
jq -n '{"example-market": {source: {source: "github", repo: "example-org/example-market"}}}' >"$dir/known_marketplaces.json"
jq -n '{version: 2, plugins: {"p1@example-market": [{scope: "user", installPath: "/nowhere", version: "1.0.0"}]}}' \
  >"$dir/installed_plugins.json"
assert_exit 0 ds a skills reconcile
assert_eq ask "$(plugin_item a p1@example-market .state)"
tip=$(remote_tip)

: >"$DS_TEST_ROOT/nix-hang"
# A session of its own, as a terminal gives it; no setsid(1) in the Nix sandbox or on macOS.
python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' bash -c 'cd "$1" && HOME=$2 DOTSTEWARD_STATE_ROOT=$3 DOTSTEWARD_MACHINE=a DOTSTEWARD_INSTANCE=$1 exec "$4" skills track p1@example-market --all </dev/null >/dev/null 2>&1' _ \
  "$(clone_of a)" "$(home_of a)" "$(state_of a)" "$DS_REPO_ROOT/cli/dotsteward" &
leader=$!
tries=0
until [[ -s $DS_TEST_ROOT/nix-pid ]]; do
  tries=$((tries + 1))
  ((tries < 600)) || ds_fail "the evaluation never started"
  sleep 0.1
done
nix_pid=$(cat "$DS_TEST_ROOT/nix-pid")
kill -TERM -- "-$leader"
wait "$leader" || true
tries=0
while kill -0 "$nix_pid" 2>/dev/null; do
  tries=$((tries + 1))
  if ((tries > 100)); then
    kill -9 "$nix_pid" 2>/dev/null || true
    ds_fail "the evaluation outlived skills track"
  fi
  sleep 0.1
done
rm -f -- "$DS_TEST_ROOT/nix-hang"
assert_eq "$tip" "$(remote_tip)"
assert_eq "" "$(git -C "$(clone_of a)" status --porcelain)"
assert_eq capture "$(plugin_item a p1@example-market .state)"

# Visible: status with its command, the session once it waited, retry publishes it.
assert_exit 0 ds a skills status
assert_contains "$DS_STDOUT" "plugin:p1@example-market: answered, not published yet: dotsteward skills retry p1@example-market"
age_field a plugin:p1@example-market detected_at 7200
HOOK_ENV=(CLAUDE_CODE_SESSION_ATTENDED=1)
hook_on a SessionStart session-start
HOOK_ENV=()
assert_contains "$HOOK_OUT" "p1@example-market"
assert_contains "$HOOK_OUT" "dotsteward skills retry <name>"
ds_code a skills retry p1@example-market
assert_eq "$tip" "$(git -C "$remote" rev-parse 'refs/heads/main^')" "one commit"
assert_eq "{}" "$(plugin_item a p1@example-market .)"
