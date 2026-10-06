# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and tests/agents/helpers.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# Helpers for the E2E runner and component run tests (tests/cli/e2e). Not a
# test file.
#
# Sourcing this file sources tests/agents/helpers.sh (the synthetic
# framework copy agents_fw, instance agents_inst, its manifest mirror,
# skills lock, framework source and generation builders; see there) and
# adds:
#   - engines/ in the framework copy, so `dotsteward settings` runs;
#   - a python3 with tomlkit first on PATH (the one on PATH when it has
#     tomlkit, as in the Nix check sandbox, else the framework's own
#     interpreter built with Nix);
#   - the canonical and legacy skill roots in HOME, so `agents check` of
#     the empty instance passes;
#   - a git repository in the instance whose origin is the configured
#     instance.remote (git@github.com:example-org/workstation.git), served
#     from the bare repository e2e_bare through tests/lib/fakessh.sh, with
#     everything committed and pushed.
# The instance therefore passes every E2E check as it is.
#
#   commit_instance [MESSAGE]  commits every change of the instance (no push)
#   publish_instance [MESSAGE] commits and pushes main to the bare remote
#   add_e2e_hook COMPONENT NAME PHASE [PROFILES_JSON]
#                              an E2E hook script (standard input) in
#                              components/COMPONENT/NAME.sh, appended to the
#                              manifest's checks.e2e
#   hook_log_script NAME       a hook body that appends "NAME" and the hook
#                              environment to $e2e_hook_log
#   activate_generation        makes agents_gen the active Home Manager
#                              generation (gcroots/current-home in HOME)
#   write_buffer               writes standard input as the settings buffer
#                              local-maintained-files/buffer.toml
#   run_e2e [ARG...]           dotsteward --instance <instance> e2e
#                              --profile workstation ARG... (standard input
#                              empty)
#   run_component [ARG...]     dotsteward --instance <instance> component ARG...
#   findings                   compact [step, code, path] triples of the
#                              --json document in DS_STDOUT

# shellcheck source=tests/agents/helpers.sh
source "$DS_REPO_ROOT/tests/agents/helpers.sh"
# shellcheck source=tests/lib/bare-remote.sh
source "$DS_REPO_ROOT/tests/lib/bare-remote.sh"
# shellcheck source=tests/lib/fakessh.sh
source "$DS_REPO_ROOT/tests/lib/fakessh.sh"

cp -R "$DS_REPO_ROOT/engines" "$agents_fw/"

_e2e_use_python() {
  if python3 -c 'import tomlkit' >/dev/null 2>&1; then
    return 0
  fi
  command -v nix >/dev/null 2>&1 ||
    ds_fail "the E2E tests need python3 with tomlkit on PATH, or nix to build it"
  local machine system out
  machine=$(uname -m)
  case $machine in
    x86_64 | amd64) machine=x86_64 ;;
    arm64 | aarch64) machine=aarch64 ;;
  esac
  case $(uname -s) in
    Linux) system=$machine-linux ;;
    Darwin) system=$machine-darwin ;;
    *) ds_fail "unsupported system: $(uname -s)" ;;
  esac
  out=$(nix --extra-experimental-features 'nix-command flakes' build --no-link \
    --print-out-paths "$DS_REPO_ROOT#packages.$system.dotsteward.python") ||
    ds_fail "cannot build the framework python with Nix"
  mkdir -p "$DS_TEST_ROOT/python/bin"
  ln -s "$out/bin/python3" "$DS_TEST_ROOT/python/bin/python3"
  export PATH=$DS_TEST_ROOT/python/bin:$PATH
}
_e2e_use_python

mkdir -p "$HOME/.agents/skills" "$HOME/.codex/skills"

e2e_remote_url='git@github.com:example-org/workstation.git'
e2e_bare=$DS_TEST_ROOT/remote.git
e2e_hook_log=$DS_TEST_ROOT/hooks.log
: >"$e2e_hook_log"

git init -q -b main "$agents_inst"
git -C "$agents_inst" add -A
git -C "$agents_inst" commit -q -m "chore: initial instance"
git init -q --bare -b main "$e2e_bare"
ds_fakessh_enable
ds_fakessh_map "$e2e_remote_url" "$e2e_bare"
git -C "$agents_inst" remote add origin "$e2e_remote_url"
git -C "$agents_inst" push -q origin main
git -C "$agents_inst" fetch -q origin

commit_instance() {
  git -C "$agents_inst" add -A
  if ! git -C "$agents_inst" diff --cached --quiet; then
    git -C "$agents_inst" commit -q -m "${1:-chore: update the instance}"
  fi
}

publish_instance() {
  commit_instance "${1:-}"
  git -C "$agents_inst" push -q origin main
  git -C "$agents_inst" fetch -q origin
}

add_e2e_hook() {
  local component=$1 name=$2 phase=$3 profiles=${4:-null}
  local script=$agents_inst/components/$component/$name.sh
  mkdir -p "$(dirname "$script")"
  {
    printf '#!%s\n' "$BASH"
    cat
  } >"$script"
  chmod 0755 "$script"
  manifest_edit '.checks.e2e += [$hook]' --argjson hook "$(jq -cn \
    --arg component "$component" --arg name "$name" --arg phase "$phase" --argjson profiles "$profiles" \
    '{ component: $component, name: $name, phase: $phase, profiles: $profiles,
       script: ("<instance>/components/" + $component + "/" + $name + ".sh") }')"
}

hook_log_script() {
  printf 'printf "%%s %%s\\n" %q "$DOTSTEWARD_COMPONENT/$DOTSTEWARD_PROFILE/$DOTSTEWARD_PROFILE_MODE/$DOTSTEWARD_CHECK_ONLY" >>%q\n' \
    "$1" "$e2e_hook_log"
}

activate_generation() {
  local state=$HOME/.local/state/home-manager/gcroots
  mkdir -p "$state"
  ln -sfn "$agents_gen" "$state/current-home"
}

write_buffer() {
  mkdir -p "$agents_inst/local-maintained-files/files"
  cat >"$agents_inst/local-maintained-files/buffer.toml"
}

run_e2e() {
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" e2e --profile workstation "$@" </dev/null
}

run_component() {
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" component "$@" </dev/null
}

findings() {
  jq -c '[.findings[] | [.step, .code, .path]]' <<<"$DS_STDOUT"
}
