#!/usr/bin/env bash
# Scenario agent-prepare: the starting point of the agentic end-to-end test.
# The VM becomes the machine of a stranger who has one coding agent and
# nothing else (no Nix, no instance): the agent is installed with its
# vendor's documented method for Linux, into the user's home, an empty bare
# repository at ~/remotes/workstation.git stands in for the instance's
# hosted remote (plain `dotsteward e2e` needs a pushed origin), and the
# owner's next steps are printed (log in, install the dotsteward plugin from
# the local marketplace in ~/dotsteward-src, ask for a workstation).
#
# Usage: bash tests/vm/guest/agent-prepare.sh --agent claude|codex
#   --agent claude  Claude Code through its native installer
#                   (https://claude.ai/install.sh, which verifies the binary
#                   it downloads), at ~/.local/bin/claude
#   --agent codex   Codex CLI from the latest GitHub release
#                   (codex-x86_64-unknown-linux-musl), at ~/.local/bin/codex
#
# Use one fresh VM per agent. Runs only inside a VM made by tests/vm/vm.sh
# (`vm.sh scenario agent-prepare -- --agent claude`); elsewhere it refuses
# before doing anything.
set -Eeuo pipefail

guest_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=tests/vm/guest/common.sh
source "$guest_dir/common.sh"

if guest_help_requested "$@"; then
  sed -n '/^# Usage:/,/^# Use one fresh VM/{/^# Use one fresh VM/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"
  exit 0
fi
guest_require_vm

agent=""
while (($#)); do
  case $1 in
    --agent)
      (($# >= 2)) || guest_die "--agent needs a value"
      agent=$2
      shift 2
      ;;
    *) guest_die "unknown argument: $1" ;;
  esac
done
case $agent in
  claude | codex) ;;
  '') guest_die "--agent claude|codex is required" ;;
  *) guest_die "unknown agent: $agent (claude or codex)" ;;
esac

bin_dir=$HOME/.local/bin
remote_dir=$HOME/remotes/workstation.git
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
download() { # URL DEST
  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    --connect-timeout 20 --retry 3 --retry-delay 5 --output "$2" "$1"
}

if command -v nix >/dev/null 2>&1 || [[ -e /nix ]]; then
  guest_die "Nix is already present: the agentic test starts from a machine without Nix (use a fresh VM)"
fi
[[ ! -e $HOME/workstation ]] || guest_die "$HOME/workstation already exists (use a fresh VM)"
[[ ! -e $remote_dir ]] || guest_die "$remote_dir already exists (use a fresh VM)"

guest_step "install $agent"
mkdir -p -- "$bin_dir"
case $agent in
  claude)
    download https://claude.ai/install.sh "$work/install.sh"
    bash "$work/install.sh"
    ;;
  codex)
    asset=codex-x86_64-unknown-linux-musl
    download "https://github.com/openai/codex/releases/latest/download/$asset.tar.gz" "$work/codex.tar.gz"
    tar -xzf "$work/codex.tar.gz" -C "$work"
    [[ -f $work/$asset && ! -L $work/$asset ]] || guest_die "the Codex release archive has no $asset binary"
    install -m 0755 -- "$work/$asset" "$bin_dir/codex"
    ;;
esac
[[ -x $bin_dir/$agent ]] || guest_die "$bin_dir/$agent was not installed"
guest_log "$("$bin_dir/$agent" --version 2>&1 | head -n 1)"

guest_step "local remote $remote_dir"
mkdir -p -- "$(dirname -- "$remote_dir")"
git init -q --bare --initial-branch=main "$remote_dir"

guest_step "next steps for the owner"
# The plugin channel of each agent (docs/getting-started-ubuntu.md), from
# the local marketplace in ~/dotsteward-src instead of the GitHub URL.
case $agent in
  claude)
    login_step='Start the agent and log in:      claude, then log in when it asks'
    plugin_step='Install the dotsteward plugin from the local marketplace in
   ~/dotsteward-src, in the Claude Code session:
     /plugin marketplace add ~/dotsteward-src
     /plugin install dotsteward@dotsteward
   (restart claude when it asks, so the plugin skills load)'
    ;;
  codex)
    login_step='Log in:                          codex login --device-auth'
    plugin_step='Install the dotsteward plugin from the local marketplace in
   ~/dotsteward-src, then start the agent:
     codex plugin marketplace add ~/dotsteward-src
     codex plugin add dotsteward@dotsteward
     codex'
    ;;
esac
cat <<EOF
1. Open a login shell in this VM:   tests/vm/vm.sh ssh --name <this VM>
2. $login_step
3. $plugin_step
4. Ask the agent, for example:
     Set up this machine as a new dotsteward workstation with the
     dotsteward-init skill. Use the framework checkout in ~/dotsteward-src
     (git+file://$guest_src) instead of the GitHub release, keep the
     instance repository in ~/workstation with file://$remote_dir
     (an existing local bare repository) as its remote, push main to it,
     and enable all six catalog components.
   Answer its questions as a new user would; approve sudo prompts.
5. When the agent reports success, check the result from the host:
     tests/vm/vm.sh scenario agent-verify --name <this VM> --no-push
EOF
