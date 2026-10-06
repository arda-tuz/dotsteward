#!/usr/bin/env bash
# Scenario agent-verify: checks the workstation an agent built with
# dotsteward-init in the agentic end-to-end test. The instance is
# initialized and committed, its working tree is clean, its branch is pushed
# to origin, Nix works, and the framework's own end-to-end check
# (`dotsteward e2e`) passes.
#
# Usage: bash tests/vm/guest/agent-verify.sh [--dir DIR] [--profile P]
#   --dir DIR    the instance the agent created (default ~/workstation)
#   --profile P  the profile to check (default: the instance's current
#                profile, as `dotsteward context --json` reports it)
#
# Runs only inside a VM made by tests/vm/vm.sh (`vm.sh scenario
# agent-verify --no-push`); elsewhere it refuses before doing anything.
set -Eeuo pipefail

guest_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=tests/vm/guest/common.sh
source "$guest_dir/common.sh"

if guest_help_requested "$@"; then
  sed -n '/^# Usage:/,/^# Runs only/{/^# Runs only/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"
  exit 0
fi
guest_require_vm

instance_dir=$HOME/workstation
profile=
while (($#)); do
  case $1 in
    --dir)
      (($# >= 2)) || guest_die "--dir needs a value"
      instance_dir=$2
      shift 2
      ;;
    --profile)
      (($# >= 2)) || guest_die "--profile needs a value"
      profile=$2
      shift 2
      ;;
    *) guest_die "unknown argument: $1" ;;
  esac
done

guest_step "instance $instance_dir"
[[ -f $instance_dir/workstation.toml ]] || guest_die "no workstation.toml in $instance_dir"
! grep -q '^# dotsteward:template' "$instance_dir/workstation.toml" ||
  guest_die "workstation.toml still carries the template marker: init did not run"
[[ -x $instance_dir/.dotsteward/cli.sh ]] || guest_die "no launcher at $instance_dir/.dotsteward/cli.sh"
git -C "$instance_dir" log -1 --format='last commit: %h %s' || guest_die "$instance_dir is not a git repository with a commit"
[[ -z $(git -C "$instance_dir" status --porcelain) ]] || {
  git -C "$instance_dir" status --short >&2
  guest_die "the instance has uncommitted changes"
}

# e2e fails at core:repo-remote unless origin holds HEAD; say so plainly
# here instead of after the Nix checks.
origin=$(git -C "$instance_dir" remote get-url origin 2>/dev/null) ||
  guest_die "the instance has no origin remote (agent-prepare made $HOME/remotes/workstation.git for it)"
guest_log "origin: $origin"
branch=$(git -C "$instance_dir" symbolic-ref --quiet --short HEAD) ||
  guest_die "the instance has a detached HEAD"
remote_oid=$(git -C "$instance_dir" ls-remote origin "refs/heads/$branch" | cut -f1) ||
  guest_die "cannot read origin: $origin"
[[ -n $remote_oid ]] || guest_die "origin has no branch $branch: push it (git -C $instance_dir push -u origin $branch)"
[[ $remote_oid == "$(git -C "$instance_dir" rev-parse HEAD)" ]] ||
  guest_die "origin $branch ($remote_oid) differs from HEAD: push the instance"

guest_step "Nix"
guest_load_nix
command -v nix >/dev/null 2>&1 || guest_die "nix is not installed"
guest_nix --version

# e2e has no default profile: without --profile, check the one the
# bootstrap activated (the last rebuild's profile, else the check profile).
if [[ -z $profile ]]; then
  guest_step "current profile"
  profile=$(cd "$instance_dir" && ./.dotsteward/cli.sh context --json |
    python3 -I -c 'import json, sys; print(json.load(sys.stdin)["profiles"]["current"])') ||
    guest_die "cannot read the current profile from dotsteward context"
  [[ -n $profile ]] || guest_die "dotsteward context reports no current profile"
  guest_log "profile: $profile"
fi

guest_step "dotsteward e2e --profile $profile"
(cd "$instance_dir" && ./.dotsteward/cli.sh e2e --profile "$profile")
guest_log "login shell: $(guest_login_shell)"

guest_step "agent-verify passed"
