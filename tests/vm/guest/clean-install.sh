#!/usr/bin/env bash
# Scenario clean-install: a new user's fresh Ubuntu 24.04 becomes a dotsteward
# workstation through the CLI alone, unattended, the way the clean-install
# workflow runs it on CI, but on a real (virtual) machine with a real login
# shell: the verified Nix install of stage-0, `init` of a template instance from
# the pushed framework checkout, the bootstrap profile (system install, rebuild
# --switch, login shell, e2e), e2e again, and a rollback.
#
# Usage: bash tests/vm/guest/clean-install.sh [--components LIST] [--dir DIR]
#                                             [--no-rollback]
#   --components LIST  comma-separated catalog components (default: all
#                      six: shell,herdr,claude-code,codex,opencode-pi,vscode)
#   --dir DIR          instance directory (default ~/workstation)
#   --no-rollback      keep the workstation (for manual inspection)
#
# Runs only inside a VM made by tests/vm/vm.sh (`vm.sh scenario
# clean-install`); elsewhere it refuses before doing anything.
set -Eeuo pipefail

guest_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=tests/vm/guest/common.sh
source "$guest_dir/common.sh"

if guest_help_requested "$@"; then
  sed -n '/^# Usage:/,/^# Runs only/{/^# Runs only/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"
  exit 0
fi
guest_require_vm

components=shell,herdr,claude-code,codex,opencode-pi,vscode
instance_dir=$HOME/workstation
rollback=1
while (($#)); do
  case $1 in
    --components)
      (($# >= 2)) || guest_die "--components needs a value"
      components=$2
      shift 2
      ;;
    --dir)
      (($# >= 2)) || guest_die "--dir needs a value"
      instance_dir=$2
      shift 2
      ;;
    --no-rollback)
      rollback=0
      shift
      ;;
    *) guest_die "unknown argument: $1" ;;
  esac
done
[[ $components =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]] || guest_die "invalid --components: $components"
[[ ! -e $instance_dir ]] || guest_die "the instance directory already exists: $instance_dir (use a fresh VM)"

# The VM harness answers the package manager's prompts.
export DOTSTEWARD_ASSUME_YES=1
remote_dir=$HOME/remotes/workstation.git
framework_url=git+file://$guest_src
fresh_profile=fresh

guest_step "machine"
os_name=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"')
guest_log "${os_name:-unknown OS}, $(uname -m), user $(id -un), shell $(guest_login_shell)"
guest_log "framework: $(git -C "$guest_src" rev-parse HEAD)"

guest_step "verified Nix install (stage-0 --install-nix-only)"
bash "$guest_src/template/bootstrap.sh" --install-nix-only
guest_load_nix
command -v nix >/dev/null 2>&1 || guest_die "nix is not on PATH after the install"
guest_nix --version

guest_step "git identity of the stranger"
git config --global user.name >/dev/null 2>&1 || git config --global user.name 'VM Stranger'
git config --global user.email >/dev/null 2>&1 || git config --global user.email 'stranger@example.invalid'
git config --global init.defaultBranch main

guest_step "init a template instance in $instance_dir"
mkdir -p -- "$(dirname -- "$remote_dir")"
git init -q --bare "$remote_dir"
init_args=(
  init --dir "$instance_dir" --remote "file://$remote_dir"
  --components "$components" --profiles "workstation,$fresh_profile"
  --framework-url "$framework_url" --non-interactive
)
[[ ,$components, != *,vscode,* ]] || init_args+=(--allow-unfree)
guest_nix run "$framework_url#dotsteward" -- "${init_args[@]}"
git -C "$instance_dir" remote get-url origin >/dev/null 2>&1 ||
  git -C "$instance_dir" remote add origin "file://$remote_dir"
git -C "$instance_dir" push -q -u origin main

guest_step "bootstrap the fresh profile"
(cd "$instance_dir" && ./bootstrap.sh --profile "$fresh_profile")
guest_load_nix

guest_step "e2e after the bootstrap"
(cd "$instance_dir" && ./.dotsteward/cli.sh e2e --profile "$fresh_profile")
guest_log "login shell is now $(guest_login_shell)"

if ((rollback)); then
  guest_step "rollback"
  (cd "$instance_dir" && ./rollback.sh --latest --apply)
  shell_after=$(guest_login_shell)
  [[ $shell_after == /bin/bash ]] || guest_die "the rollback left the login shell at $shell_after (expected /bin/bash)"
  guest_log "login shell restored to $shell_after"
fi

guest_step "clean-install passed"
