# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2034 # the ct_* and CT_* names are read by the test files
# Helpers for the local contribute tests (tests/contribute/local). Not a test
# file.
#
# Sourcing this file builds, inside DS_TEST_ROOT:
#   ct_upstream_bare  a synthetic framework upstream (bare repository on
#                     main) served for CT_UPSTREAM_URL through the fake SSH
#                     transport; its tree holds privacy/policy.toml (the
#                     framework's), privacy/allowlist.txt (the framework's
#                     plus "example-app"), a minimal tests/run.sh, the test
#                     tests/example/test-feature.sh (fails until feature.txt
#                     exists at the root), flake.nix and README.md
#   ct_fork_bare      a fork of it (same history) served for CT_FORK_URL
#   ct_inst           the instance: workstation.toml (identity alice, remote
#                     CT_INSTANCE_REMOTE, gate 2 jobs and 3 cores, the
#                     instance components example-term and example-app,
#                     upstream.local_clone = ct_clone), flake.lock with a
#                     github dotsteward input example-org/dotsteward, the
#                     settings buffer (target example-term-state, entries
#                     term-theme and term-font) and the skills lock
#                     (example-notes) from fixtures/instance
#   ct_clone          upstream.local_clone (absent until setup)
#   ct_runs           <state root>/contribute
#   ct_denylist       ~/.config/dotsteward/denylist.txt (absent until
#                     write_denylist)
# The nix and gh stubs are first on PATH; gh answers the git protocol
# (ssh), push permission on the upstream (true) and the fork (exists).
#
#   run_contribute ARG...      dotsteward --instance <instance> contribute
#                              ARG... through the dispatcher under test,
#                              standard input empty
#   write_instance [CONTRIBUTE] [TOML...]
#                              rewrites workstation.toml with
#                              upstream.contribute = CONTRIBUTE (default
#                              owner) and the extra [upstream] lines TOML
#   write_denylist             the denylist: a comment, then
#                              synthetic-private-term (line 2), mode 0600
#   write_denylist_lines LINE...
#                              the denylist with exactly these lines
#   gh_routes PROTOCOL PUSH FORK
#                              replaces the gh routes: git_protocol answer
#                              (ssh, https or none), push permission on the
#                              upstream (true, false or error) and the fork
#                              repository (exists or missing)
#   push_upstream FILE CONTENT MESSAGE
#                              a commit pushed to the upstream main from a
#                              separate clone; prints nothing
#   upstream_main, fork_main   main of the bare repositories
#   write_mirror               .dotsteward/manifest.<running system>.json
#                              with two settings targets: herdr-config of
#                              the catalog component herdr and
#                              example-term-config of the instance
#                              component example-term
#   setup_owner, setup_fork    write_denylist, the instance in that mode and
#                              a successful `contribute setup`
#   start_run SLUG             a successful `contribute start --slug SLUG`
#   clone_commit FILE CONTENT MESSAGE
#                              writes FILE in the clone and commits it with
#                              the clone's identity
#   current_id, state_json     the current run id and its state document
#   temp_leftovers             dotsteward-* entries left in TMPDIR
#   network_calls              the fake SSH log

# shellcheck source=tests/lib/bare-remote.sh
source "$DS_REPO_ROOT/tests/lib/bare-remote.sh"
# shellcheck source=tests/lib/fakessh.sh
source "$DS_REPO_ROOT/tests/lib/fakessh.sh"

CT_UPSTREAM_SLUG=example-org/dotsteward
CT_UPSTREAM_URL=git@github.com:example-org/dotsteward.git
CT_UPSTREAM_HTTPS=https://github.com/example-org/dotsteward.git
CT_FORK_SLUG=dotsteward-test/dotsteward
CT_FORK_URL=git@github.com:dotsteward-test/dotsteward.git
CT_INSTANCE_REMOTE=git@github.com:alice/workstation.git
CT_NOREPLY=1000+dotsteward-test@users.noreply.github.com

ct_fixtures=$DS_REPO_ROOT/tests/contribute/local/fixtures
ct_upstream_src=$DS_TEST_ROOT/upstream-src
ct_upstream_bare=$DS_TEST_ROOT/upstream.git
ct_fork_bare=$DS_TEST_ROOT/fork.git
ct_inst=$DS_TEST_ROOT/instance
ct_clone=$DS_TEST_ROOT/data/framework
ct_runs=$DOTSTEWARD_STATE_ROOT/contribute
ct_denylist=$HOME/.config/dotsteward/denylist.txt

# --- upstream and fork --------------------------------------------------------

ds_git_repo "$ct_upstream_src"
mkdir -p "$ct_upstream_src/privacy" "$ct_upstream_src/tests/example"
cp "$DS_REPO_ROOT/privacy/policy.toml" "$ct_upstream_src/privacy/policy.toml"
{
  cat "$DS_REPO_ROOT/privacy/allowlist.txt"
  printf '# A public name of the synthetic framework.\nexample-app\n'
} >"$ct_upstream_src/privacy/allowlist.txt"
cat >"$ct_upstream_src/tests/run.sh" <<'EOF'
#!/usr/bin/env bash
# Minimal runner of the synthetic framework: runs every named test file.
set -euo pipefail
status=0
for test in "$@"; do
  bash "$test" || status=1
done
exit "$status"
EOF
cat >"$ct_upstream_src/tests/example/test-feature.sh" <<'EOF'
#!/usr/bin/env bash
# Fails until the feature exists.
set -euo pipefail
test -f feature.txt
EOF
chmod 0755 "$ct_upstream_src/tests/run.sh" "$ct_upstream_src/tests/example/test-feature.sh"
printf '{ outputs = _: { }; }\n' >"$ct_upstream_src/flake.nix"
printf '/ignored/\n' >"$ct_upstream_src/.gitignore"
git -C "$ct_upstream_src" add -A
git -C "$ct_upstream_src" commit -q -m "feat: add the synthetic framework"
ds_bare_remote "$ct_upstream_bare" "$ct_upstream_src"
ds_bare_remote "$ct_fork_bare" "$ct_upstream_src"
ds_fakessh_enable
ds_fakessh_map "$CT_UPSTREAM_URL" "$ct_upstream_bare"
ds_fakessh_map "$CT_FORK_URL" "$ct_fork_bare"

# --- instance -----------------------------------------------------------------

mkdir -p "$ct_inst"
cp -R "$ct_fixtures/instance/." "$ct_inst/"

write_instance() {
  local contribute=${1:-owner} line
  shift || true
  cat >"$ct_inst/workstation.toml" <<EOF
schema_version = 1

[identity]
username = "alice"

[instance]
remote = "$CT_INSTANCE_REMOTE"

[nix]
state_version = "25.11"

[profiles]
names = ["main"]

[gate]
nix_max_jobs = 2
nix_cores = 3

[components.example-term]
enable = true
source = "instance"

[components.example-app]
enable = true
source = "instance"

[upstream]
contribute = "$contribute"
local_clone = "$ct_clone"
EOF
  for line in "$@"; do
    printf '%s\n' "$line" >>"$ct_inst/workstation.toml"
  done
}
write_instance owner

# --- stubs --------------------------------------------------------------------

ds_use_stubs nix gh

gh_routes() {
  (($# == 3)) || ds_fail "usage: gh_routes PROTOCOL PUSH FORK"
  ds_stub_clear_routes gh
  case $1 in
    ssh | https) ds_stub_route gh 'config get git_protocol*' --stdout "$1" ;;
    none) ;;
    *) ds_fail "gh_routes: unknown protocol $1" ;;
  esac
  case $2 in
    true | false)
      ds_stub_route gh "api repos/$CT_UPSTREAM_SLUG" \
        --stdout "{\"full_name\":\"$CT_UPSTREAM_SLUG\",\"permissions\":{\"admin\":false,\"push\":$2,\"pull\":true}}"
      ;;
    error) ds_stub_route gh "api repos/$CT_UPSTREAM_SLUG" --exit 1 --stderr 'gh: Not Found (HTTP 404)' ;;
    *) ds_fail "gh_routes: unknown push answer $2" ;;
  esac
  case $3 in
    exists) ds_stub_route gh "api repos/$CT_FORK_SLUG" --stdout "{\"full_name\":\"$CT_FORK_SLUG\",\"fork\":true}" ;;
    missing) ds_stub_route gh "api repos/$CT_FORK_SLUG" --exit 1 --stderr 'gh: Not Found (HTTP 404)' ;;
    *) ds_fail "gh_routes: unknown fork answer $3" ;;
  esac
}
gh_routes ssh true exists

# --- helpers ------------------------------------------------------------------

run_contribute() {
  "$DS_REPO_ROOT/cli/dotsteward" --instance "$ct_inst" contribute "$@" </dev/null
}

write_denylist() {
  write_denylist_lines '# synthetic private terms' synthetic-private-term
}

write_denylist_lines() {
  mkdir -p "$(dirname "$ct_denylist")"
  printf '%s\n' "$@" >"$ct_denylist"
  chmod 0600 "$ct_denylist"
}

push_upstream() {
  (($# == 3)) || ds_fail "usage: push_upstream FILE CONTENT MESSAGE"
  local clone=$DS_TEST_ROOT/elsewhere
  rm -rf -- "$clone"
  git clone -q "$ct_upstream_bare" "$clone"
  ds_git_commit "$clone" "$1" "$2" "$3"
  git -C "$clone" push -q origin HEAD:main
  rm -rf -- "$clone"
}

upstream_main() {
  git -C "$ct_upstream_bare" rev-parse refs/heads/main
}

fork_main() {
  git -C "$ct_fork_bare" rev-parse refs/heads/main
}

write_mirror() {
  local machine
  machine=$(uname -m)
  case $machine in
    amd64) machine=x86_64 ;;
    arm64) machine=aarch64 ;;
  esac
  mkdir -p "$ct_inst/.dotsteward"
  jq -n '{settings_targets: {
      "herdr-config": {component: "herdr", path: "~/.config/herdr/config.toml", format: "toml"},
      "example-term-config": {component: "example-term", path: "~/.config/example-term/config.toml", format: "toml"}}}' \
    >"$ct_inst/.dotsteward/manifest.$machine-linux.json"
}

setup_owner() {
  write_denylist
  write_instance owner
  assert_exit 0 run_contribute setup
}

setup_fork() {
  write_denylist
  write_instance fork
  assert_exit 0 run_contribute setup
}

start_run() {
  assert_exit 0 run_contribute start --slug "$1"
}

clone_commit() {
  (($# == 3)) || ds_fail "usage: clone_commit FILE CONTENT MESSAGE"
  ds_git_commit "$ct_clone" "$1" "$2" "$3"
}

current_id() {
  [[ -f $ct_runs/current ]] || ds_fail "no current contribute run"
  printf '%s\n' "$(<"$ct_runs/current")"
}

state_json() {
  local id
  id=$(current_id)
  [[ -f $ct_runs/$id.json ]] || ds_fail "no state file for run $id"
  cat "$ct_runs/$id.json"
}

temp_leftovers() {
  find "$TMPDIR" -mindepth 1 -maxdepth 1 -name 'dotsteward-*' ! -name 'dotsteward-assert.*' -print | LC_ALL=C sort
}

network_calls() {
  cat "$DS_FAKESSH_LOG"
}
