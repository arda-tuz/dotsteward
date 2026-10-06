# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the local helpers
# shellcheck disable=SC2034 # the rt_* names are read by the test files
# Helpers for the remote contribute tests (tests/contribute/remote). Not a
# test file.
#
# Sourcing this file sources tests/contribute/local/helpers.sh (the
# synthetic upstream, fork, instance and clone; see there) and adds:
#   a release of the synthetic framework: VERSION 0.1.0, template/bootstrap.sh
#                     and template/.dotsteward/cli.sh, tagged v0.1.0 (an
#                     annotated tag) on the upstream and the fork
#   rt_fw             a copy of the framework under test whose gate,
#                     rebuild, e2e, update and sync commands are recording
#                     stand-ins: each records "dotsteward-<command> ARG..."
#                     (plus "dotsteward-env DOTSTEWARD_FRAMEWORK_OVERRIDE=..."
#                     when that variable reaches it) and fails with the
#                     status of the first matching stand_in_fail rule;
#                     rebuild --switch writes the live framework to rt_live
#                     (the --framework-override value, else "pinned"); sync
#                     writes the untracked mirror .dotsteward/synced; gate
#                     refuses untracked files, as the real gate does
#   ct_inst           a git clone on main (origin CT_INSTANCE_REMOTE, served
#                     from rt_inst_bare) with flake.nix (the github form of
#                     the dotsteward input, write_flake changes it), the
#                     manifest mirror and the v0.1.0 bootstrap.sh and
#                     .dotsteward/cli.sh
#   a fake GitHub (fake-gh.sh) and a fake Nix (fake-nix.sh) behind the gh
#   and nix stubs; CI polling at one second
#
#   run_contribute ARG...      the dispatcher of rt_fw on the instance
#   rt_setup MODE [TOML...]    the denylist, workstation.toml in MODE (owner
#                              or fork) with the extra [upstream] lines,
#                              committed and pushed, then `contribute setup`
#   write_flake github|git|inline
#                              the dotsteward input as `dotsteward.url =
#                              "github:..."`, as a block with a git+ssh url
#                              (?ref=refs/tags/v0.1.0), or as a one-line
#                              block; committed and pushed
#   instance_commit MESSAGE    commits and pushes every instance change
#   hub_knob NAME VALUE        a fake GitHub or fake Nix knob
#   stand_in_fail COMMAND GLOB [STATUS]
#                              COMMAND fails (default status 1) when its
#                              arguments match GLOB; stand_in_clear COMMAND
#   checked_run SLUG [VERSION] a run on fix/SLUG with a test commit
#                              (tests/example/test-SLUG.sh) and a fix commit
#                              (SLUG.txt, VERSION (default 0.1.1) and
#                              template/bootstrap.sh of that release) whose
#                              check passed
#   rt_bootstrap VERSION       template/bootstrap.sh of a release
#   mark_checked               records the clone's HEAD as checked
#   mark_trialled KIND [SWITCHED]
#                              records a passed trial (full or build-only)
#                              on profile main
#   published_run SLUG [VERSION], released_run SLUG [VERSION]
#                              a checked run through publish (owner mode),
#                              and through release
#   state_set JQ_FILTER [JQ_OPTION...]
#                              edits the current run's state file
#   field JQ_FILTER            jq -r over the current run's state
#   call_line NAME ARG...      a call log line, as the stubs write it
#   instance_calls             the dotsteward-* lines of the call log
#   reset_calls                empties the call log
#   live                       rt_live (none before any switch)
#   upstream_tree, fork_tree   the tree of main of the bare repositories

# shellcheck source=tests/contribute/local/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/local/helpers.sh"

rt_fw=$DS_TEST_ROOT/fw
rt_inst_bare=$DS_TEST_ROOT/instance.git
rt_live=$DS_TEST_ROOT/live
rt_hub=$DS_TEST_ROOT/hub
rt_remote_dir=$DS_REPO_ROOT/tests/contribute/remote

export DOTSTEWARD_CONTRIBUTE_POLL_SECONDS=1
export DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS=1
export DOTSTEWARD_CONTRIBUTE_CI_TIMEOUT_SECONDS=60

# --- the release of the synthetic framework -----------------------------------

# rt_bootstrap VERSION: template/bootstrap.sh of a release.
rt_bootstrap() {
  printf '#!/usr/bin/env bash\n# Stage-0 of the synthetic framework, release %s.\n' "$1"
}
rt_launcher_v1='#!/usr/bin/env bash
# Launcher of the synthetic framework, release 0.1.0.
'
mkdir -p "$ct_upstream_src/template/.dotsteward"
printf '0.1.0\n' >"$ct_upstream_src/VERSION"
rt_bootstrap 0.1.0 >"$ct_upstream_src/template/bootstrap.sh"
printf '%s' "$rt_launcher_v1" >"$ct_upstream_src/template/.dotsteward/cli.sh"
chmod 0755 "$ct_upstream_src/template/bootstrap.sh" "$ct_upstream_src/template/.dotsteward/cli.sh"
git -C "$ct_upstream_src" add -A
git -C "$ct_upstream_src" commit -q -m "feat: add the release files"
git -C "$ct_upstream_src" tag -a v0.1.0 -m "dotsteward v0.1.0"
git -C "$ct_upstream_src" push -q "$ct_upstream_bare" main refs/tags/v0.1.0
git -C "$ct_upstream_src" push -q "$ct_fork_bare" main refs/tags/v0.1.0

# --- the framework copy with stand-ins --------------------------------------------

mkdir -p "$rt_fw"
cp -R "$DS_REPO_ROOT/cli" "$DS_REPO_ROOT/privacy" "$DS_REPO_ROOT/schema" "$DS_REPO_ROOT/VERSION" \
  "$DS_REPO_ROOT/modules" "$rt_fw/"
for command in gate rebuild e2e update sync; do
  {
    printf '# summary: stand-in %s of the remote contribute tests\n' "$command"
    printf 'set -euo pipefail\n'
    printf 'source %q\n' "$DS_REPO_ROOT/tests/lib/harness.sh"
    printf 'ds_record_call dotsteward-%s "$@"\n' "$command"
    cat <<'EOF'
if [[ -n ${DOTSTEWARD_FRAMEWORK_OVERRIDE+set} ]]; then
  ds_record_call dotsteward-env "DOTSTEWARD_FRAMEWORK_OVERRIDE=$DOTSTEWARD_FRAMEWORK_OVERRIDE"
fi
EOF
    printf 'rules=%q\n' "$DS_TEST_ROOT/stand-ins/$command"
    cat <<'EOF'
if [[ -f $rules ]]; then
  while IFS=$'\t' read -r pattern status; do
    # shellcheck disable=SC2053 # the rule is a glob on purpose
    if [[ "$*" == $pattern ]]; then
      printf 'stand-in failure\n' >&2
      exit "$status"
    fi
  done <"$rules"
fi
EOF
    case $command in
      rebuild)
        printf 'live=%q\n' "$rt_live"
        cat <<'EOF'
if [[ " $* " == *" --switch "* ]]; then
  framework=pinned
  args=("$@")
  for ((i = 0; i < ${#args[@]} - 1; i++)); do
    [[ ${args[i]} != --framework-override ]] || framework=${args[i + 1]}
  done
  printf '%s\n' "$framework" >"$live"
fi
EOF
        ;;
      sync)
        cat <<'EOF'
printf 'synced\n' >"$DOTSTEWARD_INSTANCE/.dotsteward/synced"
EOF
        ;;
      gate)
        cat <<'EOF'
untracked=$(git -C "$DOTSTEWARD_INSTANCE" ls-files --others --exclude-standard)
if [[ -n $untracked ]]; then
  printf "[dotsteward] ERROR: Nix does not see untracked files; run 'git add -A' first: %s\n" "$untracked" >&2
  exit 1
fi
EOF
        ;;
    esac
  } >"$rt_fw/cli/commands/$command.sh"
done

run_contribute() {
  "$rt_fw/cli/dotsteward" --instance "$ct_inst" contribute "$@" </dev/null
}

# --- fake GitHub and Nix ------------------------------------------------------------

mkdir -p "$rt_hub/knobs"
printf '%s\t%s\n' "$CT_UPSTREAM_SLUG" "$ct_upstream_bare" "$CT_FORK_SLUG" "$ct_fork_bare" >"$rt_hub/repos"
ds_stub_override gh <"$rt_remote_dir/fake-gh.sh"
ds_stub_override nix <"$rt_remote_dir/fake-nix.sh"

hub_knob() {
  (($# == 2)) || ds_fail "usage: hub_knob NAME VALUE"
  printf '%s\n' "$2" >"$rt_hub/knobs/$1"
}

stand_in_fail() {
  (($# == 2 || $# == 3)) || ds_fail "usage: stand_in_fail COMMAND GLOB [STATUS]"
  mkdir -p "$DS_TEST_ROOT/stand-ins"
  printf '%s\t%s\n' "$2" "${3:-1}" >>"$DS_TEST_ROOT/stand-ins/$1"
}

stand_in_clear() {
  rm -f "$DS_TEST_ROOT/stand-ins/$1"
}

# --- instance -------------------------------------------------------------------------

instance_commit() {
  git -C "$ct_inst" add -A
  if ! git -C "$ct_inst" diff --cached --quiet; then
    git -C "$ct_inst" commit -q -m "$1"
  fi
  git -C "$ct_inst" push -q origin HEAD:main
}

write_flake() {
  case $1 in
    github)
      cat >"$ct_inst/flake.nix" <<'EOF'
{
  inputs = {
    # dotsteward:inputs:begin
    dotsteward.url = "github:example-org/dotsteward/v0.1.0";
    # dotsteward:inputs:end
  };
  outputs = inputs: inputs.dotsteward.lib.mkInstance { inherit inputs; };
}
EOF
      ;;
    git)
      cat >"$ct_inst/flake.nix" <<'EOF'
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/774debe7a0d1b496e35677ad955a1011c6ff74f3";
    dotsteward = {
      # The framework release.
      url = "git+ssh://git@github.com/example-org/dotsteward?ref=refs/tags/v0.1.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = inputs: inputs.dotsteward.lib.mkInstance { inherit inputs; };
}
EOF
      ;;
    inline)
      cat >"$ct_inst/flake.nix" <<'EOF'
{
  inputs.dotsteward = { url = "github:example-org/dotsteward?ref=v0.1.0&dir=."; flake = true; };
  outputs = inputs: inputs.dotsteward.lib.mkInstance { inherit inputs; };
}
EOF
      ;;
    *) ds_fail "write_flake: unknown form $1" ;;
  esac
  instance_commit "chore: use the $1 form of the dotsteward input"
}

write_mirror
mkdir -p "$ct_inst/.dotsteward"
rt_bootstrap 0.1.0 >"$ct_inst/bootstrap.sh"
printf '%s' "$rt_launcher_v1" >"$ct_inst/.dotsteward/cli.sh"
chmod 0755 "$ct_inst/bootstrap.sh" "$ct_inst/.dotsteward/cli.sh"
git init -q -b main "$ct_inst"
git -C "$ct_inst" add -A
git -C "$ct_inst" commit -q -m "chore: initialize the instance"
git init -q --bare -b main "$rt_inst_bare"
git -C "$ct_inst" remote add origin "$CT_INSTANCE_REMOTE"
ds_fakessh_map "$CT_INSTANCE_REMOTE" "$rt_inst_bare"
write_flake github

rt_setup() {
  (($# >= 1)) || ds_fail "usage: rt_setup MODE [TOML...]"
  write_denylist
  write_instance "$@"
  instance_commit "chore: contribute in $1 mode"
  assert_exit 0 run_contribute setup
}

# --- runs -----------------------------------------------------------------------------

state_set() {
  local id file
  id=$(current_id)
  file=$ct_runs/$id.json
  jq "${@:2}" "$1" "$file" >"$file.new"
  chmod 0600 "$file.new"
  mv "$file.new" "$file"
}

field() {
  state_json | jq -r "$1"
}

mark_checked() {
  # shellcheck disable=SC2016 # jq variables
  state_set '.test_sha = $head | .tested_tree = $tree | .step = "trial"' \
    --arg head "$(git -C "$ct_clone" rev-parse HEAD)" --arg tree "$(git -C "$ct_clone" rev-parse 'HEAD^{tree}')"
}

mark_trialled() {
  # shellcheck disable=SC2016 # jq variables
  state_set '.trial = $kind | .trial_sha = .test_sha | .profile = "main" | .trial_switched = $switched
    | .step = "publish"' --arg kind "$1" --argjson switched "${2:-false}"
}

checked_run() {
  local slug=$1 version=${2:-0.1.1}
  start_run "$slug"
  printf '#!/usr/bin/env bash\nset -euo pipefail\ntest -f %s.txt\n' "$slug" >"$ct_clone/tests/example/test-$slug.sh"
  git -C "$ct_clone" add -A
  git -C "$ct_clone" commit -q -m "test(example): cover $slug"
  printf '%s\n' "$slug" >"$ct_clone/$slug.txt"
  printf '%s\n' "$version" >"$ct_clone/VERSION"
  rt_bootstrap "$version" >"$ct_clone/template/bootstrap.sh"
  git -C "$ct_clone" add -A
  git -C "$ct_clone" commit -q -m "feat(example): $slug"
  mark_checked
}

published_run() {
  checked_run "$@"
  mark_trialled full false
  assert_exit 0 run_contribute publish
}

released_run() {
  published_run "$@"
  assert_exit 0 run_contribute release
}

# --- inspection -----------------------------------------------------------------------

call_line() {
  local line=$1
  shift
  if (($#)); then
    line+=$(printf ' %q' "$@")
  fi
  printf '%s\n' "$line"
}

instance_calls() {
  grep '^dotsteward-' "$DS_CALL_LOG" || true
}

reset_calls() {
  : >"$DS_CALL_LOG"
}

live() {
  if [[ -f $rt_live ]]; then
    cat "$rt_live"
  else
    printf 'none\n'
  fi
}

upstream_tree() {
  git -C "$ct_upstream_bare" rev-parse 'refs/heads/main^{tree}'
}

fork_tree() {
  git -C "$ct_fork_bare" rev-parse 'refs/heads/main^{tree}'
}
