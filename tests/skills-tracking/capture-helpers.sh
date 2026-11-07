# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs and scripts are single-quoted on purpose
# Helpers for the tests of `skills capture` (tests/skills-tracking). Not a test file.
#
# A bare remote and machines: each machine has its own clone, home and state root and
# passes `static` and `pins check`, and the launcher of a worktree runs the CLI under
# test. A real push goes to the bare remote, never anywhere else.
#
#   new_machine NAME      clones the remote for the machine NAME
#   on NAME COMMAND...    COMMAND with the environment of the machine
#   ds NAME ARG...        dotsteward ARG... on the machine, standard input empty
#   ds_code NAME ARG...   the same; sets DS_STDOUT, DS_STDERR and DS_STATUS, any status
#   new_skill NAME SKILL  a skill in ~/.claude/skills of the machine, where an agent
#                         writes it, without a license
#   wrote NAME SKILL      what the hook sees when a file tool wrote its SKILL.md, in the
#                         session HOOK_SESSION
#   hook_on NAME EVENT FIXTURE
#                         what the agent of the machine does for EVENT, in the session
#                         HOOK_SESSION with the variables of HOOK_ENV; sets HOOK_OUT
#   age_field NAME KEY FIELD SECONDS
#                         makes a time in the pending item KEY SECONDS older
#   own_new NAME SKILL    new_skill and wrote
#   settle NAME SKILL     its files are of an age: capture takes them at once
#   remote_file PATH      the file in the tip of the remote
#   remote_tip            the tip of the remote
#   remote_lock FILTER    jq -c FILTER over the lock in the tip of the remote
#   remote_entry SKILL    its lock entry in the tip of the remote
#   home_of NAME, clone_of NAME, state_of NAME
#   item NAME SKILL JQ    jq -r JQ over the pending item of the skill on the machine
#   base NAME SKILL       the base digest of the skill on the machine, or none
#   local_digest NAME PATH the directory digest of a path
#   wrap_git              puts the git wrapper first on PATH (GIT_WRAP_* below)
#   notified              the calls of notify-send so far
#
# The git wrapper. GIT_WRAP_BEFORE_PUSH=SCRIPT runs SCRIPT before the first push of
# a run, and removes it; GIT_WRAP_LOSE_REPLY=FILE: while FILE exists a push reaches the
# remote and its answer is lost, once; GIT_WRAP_STALL_COMMIT=FILE: a commit writes its
# process id and the one of its parent to FILE and waits, for a test to kill them;
# GIT_WRAP_PUSH_SAYS=TEXT: a push says TEXT and exits 1; GIT_WRAP_FAIL_WORKTREE=1: adding a
# worktree fails.

# shellcheck source=tests/static/helpers.sh
source "$DS_REPO_ROOT/tests/static/helpers.sh"
# shellcheck source=tests/lib/bare-remote.sh
source "$DS_REPO_ROOT/tests/lib/bare-remote.sh"
# shellcheck source=tests/lib/fixture-system.sh
source "$DS_REPO_ROOT/tests/lib/fixture-system.sh"

world=$DS_TEST_ROOT/world
remote=$world/remote.git
seed=$world/seed
fixtures=$DS_REPO_ROOT/tests/skills-tracking/fixtures
mkdir -p "$world" "$DS_TEST_ROOT/bin"
export DOTSTEWARD_CLI=$DS_REPO_ROOT/cli/dotsteward DOTSTEWARD_CAPTURE_DELAY=3600
export PATH=$DS_TEST_ROOT/bin:$PATH

python3 -c 'import tomlkit' >/dev/null 2>&1 || ds_fail "these tests need python3 with tomlkit on PATH"

# A record of what the machine tells the desktop.
cat >"$DS_TEST_ROOT/bin/notify-send" <<NOTIFY
#!$BASH
printf '%s\n' "\$*" >>"$DS_TEST_ROOT/notifications"
NOTIFY
chmod 0755 "$DS_TEST_ROOT/bin/notify-send"
: >"$DS_TEST_ROOT/notifications"

make_instance "$seed"
sed -i -e 's/^username = "alice"$/username = "dotsteward-test"/' \
  -e "/^\[nix\]\$/a systems = [\"$fixture_system\"]" "$seed/workstation.toml"
printf '\n[skills]\ntracking = true\n' >>"$seed/workstation.toml"
mkdir -p "$seed/.dotsteward"
jq -n --arg system "$fixture_system" --arg platform "$fixture_platform" '{
  schema_version: 1, system: $system, platform: $platform, framework: { version: "0.0.0" },
  components: [], probes: [], pins: { rules: [], latest: [] },
  checks: { commands: [], e2e: [], agents: [], floors: [] },
  hooks: { pre_activate: [], system_install: [], post_install: [], forbid: [],
           agents_install: [], agents_migrate: [], agents_post: [], desktop_apply: [] },
  skill_layout: {
    legacy_roots: ["~/.codex/skills"],
    link_roots: { "~/.claude/skills": { component: "claude-code", target_prefix: "../../.agents/skills/" } },
    excluded_subtrees: [".system"]
  },
  skills: { hm_root: ".agents/skills", framework: [], home_managed: [], framework_manifest: null }
}' >"$seed/.dotsteward/manifest.$fixture_system.json"
# What `pins check` of an instance without inputs needs.
jq '. + {flake_inputs: {}, nix: {version: "2.31.2", installer_url: "https://releases.example.invalid/nix/nix-2.31.2/install",
  installer_size: 4499, installer_sha256: "105a596de51480d4c4aa1ea792a2ef370e86e2f53a9c6b3ead3a70888bbbfe64"}}' \
  "$seed/versions.lock.json" >"$seed/versions.lock.tmp"
mv -- "$seed/versions.lock.tmp" "$seed/versions.lock.json"
printf '{\n  "nodes": {"root": {"inputs": {}}},\n  "root": "root",\n  "version": 7\n}\n' >"$seed/flake.lock"
printf '{\n  description = "Synthetic instance";\n  inputs = { };\n  outputs = _: { };\n}\n' >"$seed/flake.nix"
commit_instance "$seed"
git -C "$seed" branch -q -M main
git init -q --bare -b main "$remote"
git -C "$remote" config receive.denyNonFastForwards true
git -C "$remote" config receive.denyDeletes true
git -C "$seed" push -q "$remote" main

machines=()

new_machine() {
  local root=$world/$1
  mkdir -p "$root/home/.claude/skills" "$root/home/.agents/skills" "$root/home/.codex/skills" "$root/state"
  git clone -q "$remote" "$root/clone"
  machines+=("$1")
  ds "$1" skills hooks install --agent claude >/dev/null
}

home_of() { printf '%s\n' "$world/$1/home"; }
clone_of() { printf '%s\n' "$world/$1/clone"; }
state_of() { printf '%s\n' "$world/$1/state"; }

on() {
  local name=$1
  shift
  (
    export HOME=$world/$name/home DOTSTEWARD_STATE_ROOT=$world/$name/state DOTSTEWARD_MACHINE=$name \
      DOTSTEWARD_INSTANCE=$world/$name/clone
    cd "$world/$name/clone" || exit
    "$@"
  )
}

ds() {
  local name=$1
  shift
  on "$name" "$DS_REPO_ROOT/cli/dotsteward" "$@" </dev/null
}

ds_code() {
  assert_exit "${EXPECT_STATUS:-0}" ds "$@"
}

new_skill() {
  local dir
  dir=$(home_of "$1")/.claude/skills/$2
  mkdir -p "$dir/references"
  printf -- '---\nname: %s\ndescription: Synthetic skill.\n---\n\n# %s\n' "$2" "$2" >"$dir/SKILL.md"
  printf '# Guide\n' >"$dir/references/guide.md"
}

HOOK_SESSION=fe058fc9
HOOK_ENV=()
HOOK_OUT=

wrote() {
  local file
  file=$(home_of "$1")/.claude/skills/$2/SKILL.md
  on "$1" bash -c 'sed -e "s|@HOME@|$HOME|g" -e "s|@CWD@|$PWD|g" -e "s|@SESSION@|$4|g" -e "s|@FILE@|$2|g" "$1" |
    "$3" skills hook PostToolUse --agent claude' _ "$fixtures/claude/post-tool-use-write.json" "$file" \
    "$DS_REPO_ROOT/cli/dotsteward" "$HOOK_SESSION"
}

hook_on() {
  # shellcheck disable=SC2034 # read by the tests
  HOOK_OUT=$(on "$1" env ${HOOK_ENV[@]+"${HOOK_ENV[@]}"} bash -c \
    'sed -e "s|@HOME@|$HOME|g" -e "s|@CWD@|$PWD|g" -e "s|@SESSION@|$2|g" "$1" | "$3" skills hook "$4" --agent claude' \
    _ "$fixtures/claude/$3.json" "$HOOK_SESSION" "$DS_REPO_ROOT/cli/dotsteward" "$2")
}

age_field() {
  local pending
  pending=$(state_of "$1")/skills/pending.json
  jq --arg key "$2" --arg field "$3" --argjson seconds "$4" '.items[$key][$field] -= $seconds' "$pending" >"$pending.tmp"
  mv -- "$pending.tmp" "$pending"
}

own_new() {
  new_skill "$1" "$2"
  wrote "$1" "$2"
}

settle() {
  find "$(home_of "$1")/.claude/skills/$2" -exec touch -h -d '2001-01-01' {} +
}

remote_tip() {
  git -C "$remote" rev-parse refs/heads/main
}

remote_file() {
  git -C "$remote" show "refs/heads/main:$1"
}

remote_lock() {
  git -C "$remote" show refs/heads/main:agent/skills.lock.json | jq -c "$1"
}

remote_entry() {
  # shellcheck disable=SC2016 # a jq program
  git -C "$remote" show refs/heads/main:agent/skills.lock.json |
    jq -c --arg name "$1" 'first(.skills[] | select(.name == $name)) // {}'
}

item() {
  local pending
  pending=$(state_of "$1")/skills/pending.json
  if [[ ! -f $pending ]]; then
    jq -rn "{} | $3"
    return 0
  fi
  jq -r --arg key "skill:$2" ".items[\$key] // {} | $3" "$pending"
}

base() {
  jq -r --arg key "skill:$2" '.[$key].base_sha256 // "none"' "$(state_of "$1")/skills/base.json"
}

local_digest() {
  bash -c 'source "$1/cli/lib/lib.sh"; directory_sha256 "$2"' _ "$DS_REPO_ROOT" "$1"
}

notified() {
  cat "$DS_TEST_ROOT/notifications"
}

wrap_git() {
  local real
  real=$(command -v git)
  cat >"$DS_TEST_ROOT/bin/git" <<WRAP
#!$BASH
for argument in "\$@"; do
  case \$argument in
    worktree)
      if [[ -n \${GIT_WRAP_FAIL_WORKTREE:-} && " \$* " == *" worktree add "* ]]; then
        printf 'fatal: cannot make a worktree here\n' >&2
        exit 128
      fi
      break
      ;;
    push)
      if [[ -n \${GIT_WRAP_PUSH_SAYS:-} ]]; then
        printf '%s\n' "\$GIT_WRAP_PUSH_SAYS" >&2
        exit 1
      fi
      if [[ -n \${GIT_WRAP_BEFORE_PUSH:-} && -f \$GIT_WRAP_BEFORE_PUSH ]]; then
        script=\$GIT_WRAP_BEFORE_PUSH.run
        mv -- "\$GIT_WRAP_BEFORE_PUSH" "\$script"
        (unset GIT_WRAP_BEFORE_PUSH; PATH=\${PATH#*:} "$BASH" "\$script") >/dev/null 2>&1
      fi
      if [[ -n \${GIT_WRAP_LOSE_REPLY:-} && -f \$GIT_WRAP_LOSE_REPLY ]]; then
        rm -f -- "\$GIT_WRAP_LOSE_REPLY"
        "$real" "\$@" >/dev/null 2>&1
        printf 'fatal: the remote end hung up unexpectedly\n' >&2
        exit 128
      fi
      break
      ;;
    commit)
      if [[ -n \${GIT_WRAP_STALL_COMMIT:-} ]]; then
        printf '%s %s\n' "\$\$" "\$PPID" >"\$GIT_WRAP_STALL_COMMIT"
        exec sleep 600
      fi
      break
      ;;
  esac
done
exec "$real" "\$@"
WRAP
  chmod 0755 "$DS_TEST_ROOT/bin/git"
}

_capture_cleanup() {
  local name pid
  for name in "${machines[@]}"; do
    [[ -f $(state_of "$name")/skills/capture.log ]] || continue
    while read -r pid; do
      [[ -z $pid ]] || kill -9 "$pid" 2>/dev/null || true
    done < <(sed -n -e 's/^[^ ]* sleeper pid //p' -e 's/^[^ ]* capture pid //p' "$(state_of "$name")/skills/capture.log")
  done
}
ds_defer _capture_cleanup
