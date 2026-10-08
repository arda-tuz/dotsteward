# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs and literal texts are single-quoted on purpose
# All or nothing: when a step fails (nix flake lock, the mirrors
# of dotsteward sync, its pins sync, dotsteward pins check, the git commit)
# or init is terminated while a step runs, the target is as it was: a
# missing directory stays missing, an empty one stays empty (with its
# mode), a template directory keeps every byte; the temporary directory is
# gone and the step that failed is named.
# shellcheck source=tests/instance/init/helpers.sh
source "$DS_REPO_ROOT/tests/instance/init/helpers.sh"

init_use_nix
mkdir -p "$DS_TEST_ROOT/instances"
dir=$DS_TEST_ROOT/instances/station

# prepare KIND: the target as missing, empty (mode 0750) or template.
prepare() {
  rm -rf "$dir"
  case $1 in
    missing) ;;
    empty)
      mkdir "$dir"
      chmod 0750 "$dir"
      ;;
    template)
      mkdir "$dir"
      cp -R "$tpl/." "$dir/"
      chmod -R u+w "$dir"
      git -C "$dir" init -q -b main
      ;;
  esac
}

# fails_at STEP STATUS KIND ENV=VALUE...: init of a KIND target with the
# environment fails naming STEP and its exit STATUS and leaves the target as
# it was.
fails_at() {
  local step=$1 status=$2 kind=$3 before
  shift 3
  prepare "$kind"
  before=$(tree_state "$dir")
  assert_exit 1 env "$@" "$DS_CLI" init --dir "$dir" --remote "$init_remote" --components shell,opencode-pi
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: $step failed (exit $status); $dir was left as it was"
  assert_unchanged "$dir" "$before" "$step failed with a $kind target"
  assert_eq "" "$(init_temp_dirs)" "no temporary directory is left ($step, $kind)"
}

for kind in missing empty template; do
  fails_at "nix flake lock" 1 "$kind" DS_INIT_NIX_FAIL='flake lock *'
  fails_at "dotsteward sync --nix" 1 "$kind" DS_INIT_NIX_FAIL='eval *#dotstewardMirrors'
  # The pins sync of `dotsteward sync`, then the pins check after it (the
  # pins engine exits 2 for a broken input).
  fails_at "dotsteward sync --nix" 2 "$kind" DS_INIT_NIX_FAIL='eval *#lib.pinnedVersions'
  rm -f "$DS_STUB_STATE/nix/fail-matches"
  fails_at "dotsteward pins check --nix" 2 "$kind" DS_INIT_NIX_FAIL='eval *#lib.pinnedVersions' DS_INIT_NIX_FAIL_SKIP=1
  rm -f "$DS_STUB_STATE/nix/fail-matches"
done
assert_contains "$DS_STDERR" "error: injected failure of: nix eval --json --no-update-lock-file"

# A pins inconsistency the check reports (the sync before it passes): a seed
# whose OpenCode URL does not name the pinned version.
fw=$(framework_copy)
jq '.versions_lock.agent_tools.opencode.url |= sub("v[0-9.]+/"; "v0.0.1/")' "$DS_REPO_ROOT/modules/components/opencode-pi/seed.json" \
  >"$fw/modules/components/opencode-pi/seed.json"
prepare missing
assert_exit 1 "$fw/cli/dotsteward" init --dir "$dir" --remote "$init_remote" --components opencode-pi
assert_contains "$DS_STDERR" "[pins] ERROR: agent_tools.opencode.url"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: dotsteward pins check --nix failed (exit 1); $dir was left as it was"
[[ ! -e $dir ]] || ds_fail "a failed init created $dir"

# The commit fails (a global pre-commit hook refuses it).
mkdir -p "$DS_TEST_ROOT/hooks"
printf '#!%s\necho "pre-commit: refused" >&2\nexit 1\n' "$BASH" >"$DS_TEST_ROOT/hooks/pre-commit"
chmod 0755 "$DS_TEST_ROOT/hooks/pre-commit"
git config --global core.hooksPath "$DS_TEST_ROOT/hooks"
for kind in missing empty template; do
  fails_at "git commit" 1 "$kind"
done
assert_contains "$DS_STDERR" "pre-commit: refused"

# The commit runs in --dir once every entry is in place; terminated while it
# runs (its pre-commit hook hangs), init puts the target back as it was.
printf '#!%s\nprintf "%%s\\n" "$$" >"%s/hook-pid"\nexec sleep 60\n' "$BASH" "$DS_TEST_ROOT" \
  >"$DS_TEST_ROOT/hooks/pre-commit"
for kind in missing empty template; do
  prepare "$kind"
  before=$(tree_state "$dir")
  rm -f "$DS_TEST_ROOT/hook-pid"
  "$DS_CLI" init --dir "$dir" --remote "$init_remote" >"$DS_TEST_ROOT/out" 2>"$DS_TEST_ROOT/err" &
  pid=$!
  for _ in $(seq 1 600); do
    [[ -s $DS_TEST_ROOT/hook-pid ]] && break
    sleep 0.1
  done
  [[ -s $DS_TEST_ROOT/hook-pid ]] || ds_fail "the commit never started ($kind): $(<"$DS_TEST_ROOT/err")"
  kill -TERM "$pid"
  status=0
  wait "$pid" || status=$?
  kill -KILL "$(<"$DS_TEST_ROOT/hook-pid")" 2>/dev/null || true
  assert_eq 143 "$status" "exit status after SIGTERM during the commit ($kind)"
  assert_contains "$(<"$DS_TEST_ROOT/err")" "[dotsteward] ERROR: terminated; nothing was written to --dir"
  assert_unchanged "$dir" "$before" "terminated during the commit with a $kind target"
  assert_eq "" "$(init_temp_dirs)" "no temporary directory is left after SIGTERM during the commit ($kind)"
done
git config --global --unset core.hooksPath

# --- terminated while a step runs --------------------------------------------------------

for kind in missing template; do
  prepare "$kind"
  before=$(tree_state "$dir")
  rm -f "$DS_STUB_STATE/nix/hanging"
  DS_INIT_NIX_HANG='eval *#dotstewardMirrors' "$DS_CLI" init --dir "$dir" --remote "$init_remote" \
    >"$DS_TEST_ROOT/out" 2>"$DS_TEST_ROOT/err" &
  pid=$!
  for _ in $(seq 1 600); do
    [[ -s $DS_STUB_STATE/nix/hanging ]] && break
    sleep 0.1
  done
  [[ -s $DS_STUB_STATE/nix/hanging ]] || ds_fail "the step never started"
  hanging=$(<"$DS_STUB_STATE/nix/hanging")
  kill -TERM "$pid"
  status=0
  wait "$pid" || status=$?
  assert_eq 143 "$status" "exit status after SIGTERM ($kind)"
  assert_contains "$(<"$DS_TEST_ROOT/err")" "[dotsteward] ERROR: terminated; nothing was written to --dir"
  assert_unchanged "$dir" "$before" "terminated with a $kind target"
  assert_eq "" "$(init_temp_dirs)" "no temporary directory is left after SIGTERM ($kind)"
  for _ in $(seq 1 50); do
    kill -0 "$hanging" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$hanging" 2>/dev/null; then
    kill -KILL "$hanging" 2>/dev/null || true
    ds_fail "the running step was not stopped"
  fi
done
