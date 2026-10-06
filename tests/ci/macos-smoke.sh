#!/usr/bin/env bash
# macOS smoke test on a GitHub-hosted macos-14 (arm64) runner: a new
# instance for aarch64-darwin with every catalog component on its darwin
# method, built, activated in the runner's own home and checked end to end,
# the path a Mac that is already set up takes (the adopt profile).
#
# Usage: tests/ci/macos-smoke.sh
#
# Steps, the first failure stops the run:
#   1. the pinned Nix through the framework's stage 0 (template/bootstrap.sh
#      --install-nix-only with DOTSTEWARD_ASSUME_YES=1, run by /bin/bash as on
#      a stock Mac; the pin is template/versions.lock.json beside it), then
#      the Nix daemon profile is sourced;
#   2. `dotsteward init` from this checkout (`nix run path:<checkout>#dotsteward`)
#      into ~/workstation: nix.systems = aarch64-darwin, all six catalog
#      components with their darwin methods (shell and herdr nix; claude-code,
#      codex and opencode-pi official-binary; vscode app-archive), the
#      framework input path:<checkout> (a shallow checkout cannot be a
#      git+file input) and a local bare repository as instance.remote;
#   3. the instance is pushed to that remote, so the E2E repository checks
#      run for real;
#   4. through the instance launcher (.dotsteward/cli.sh, which builds the
#      CLI the instance pins): rebuild --build-only, then rebuild --switch,
#      both with the adopt profile (default), in the runner's home;
#   5. login-shell set (the shell component makes the Nix zsh the login
#      shell; rebuild only migrates it);
#   6. e2e --keep-going for that profile, so a single run reports every
#      failing check. In an adopt profile the system-level app-archive
#      install is not managed, so the catalog subset E2E covers is
#      everything else: commands, links, agent rules, agent tools, settings
#      files (the darwin paths), the herdr login zsh, the login shell, the
#      repository and the framework skills.
# On a failure the redacted `dotsteward doctor` report is printed.
#
# It installs Nix with sudo and activates Home Manager in the real home, so
# it runs only on a GitHub Actions macOS arm64 runner (GITHUB_ACTIONS=true);
# .github/workflows/macos-smoke.yml dispatches it. The script itself keeps
# to bash 3.2 and BSD tools until the dotsteward CLI takes over.
set -Eeuo pipefail

die() {
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then
    printf '::error title=macos-smoke::%s\n' "$*"
  fi
  printf '[dotsteward] ERROR: macos-smoke: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[dotsteward] macos-smoke: %s\n' "$*" >&2
}

usage() {
  sed -n '2,/^set -Eeuo pipefail$/{/^set /d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"
}

case ${1:-} in
  -h | --help)
    usage
    exit 0
    ;;
esac
(($# == 0)) || die "usage: macos-smoke.sh"

[[ ${GITHUB_ACTIONS:-} == true ]] || die "runs only on GitHub Actions runners: it installs Nix and activates the real home"
[[ $(uname -s) == Darwin ]] || die "runs only on macOS runners"
[[ $(uname -m) == arm64 ]] || die "runs only on Apple silicon (arm64) runners"
[[ -n ${RUNNER_TEMP:-} && -d $RUNNER_TEMP ]] || die "RUNNER_TEMP is not a directory"
[[ -n ${HOME:-} && -d $HOME ]] || die "HOME is not a directory"

framework_root=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
[[ -f $framework_root/flake.nix && -f $framework_root/template/bootstrap.sh ]] ||
  die "not a dotsteward checkout: $framework_root"

USER=${USER:-$(id -un)}
export USER
profile=workstation
instance=$HOME/workstation
remote=$RUNNER_TEMP/workstation.git
features='nix-command flakes'

# The commit of `dotsteward init` uses the user's own git identity; a runner
# has none.
export GIT_AUTHOR_NAME=dotsteward-smoke GIT_AUTHOR_EMAIL=dotsteward-smoke@users.noreply.github.com
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL

current_step=''

# on_exit: after a failure, the failing step and the redacted health report
# of the instance (when it exists by then).
on_exit() {
  local status=$?
  ((status != 0)) || return 0
  if [[ -n $current_step ]]; then
    printf '::endgroup::\n'
    printf '::error title=macos-smoke::%s failed (exit %s)\n' "$current_step" "$status"
  fi
  if [[ -x $instance/.dotsteward/cli.sh ]]; then
    printf '::group::%s\n' "dotsteward doctor --redact"
    "$instance/.dotsteward/cli.sh" doctor --redact >&2 || true
    printf '::endgroup::\n'
  fi
}
trap on_exit EXIT

# step TITLE COMMAND [ARG...]: COMMAND in a collapsible log group; errexit
# stays in force inside it, so its first failing command stops the run.
step() {
  current_step=$1
  shift
  printf '::group::%s\n' "$current_step"
  "$@"
  printf '::endgroup::\n'
  current_step=''
}

# cli COMMAND [ARG...]: the dotsteward CLI the instance pins.
cli() {
  "$instance/.dotsteward/cli.sh" "$@"
}

install_nix() {
  DOTSTEWARD_ASSUME_YES=1 /bin/bash "$framework_root/template/bootstrap.sh" --install-nix-only
}

machine_facts() {
  printf 'macOS %s on %s, user %s, home %s\n' "$(sw_vers -productVersion)" "$(uname -m)" "$USER" "$HOME"
  xcode-select -p
  nix --version
}

init_instance() {
  [[ ! -e $instance ]] || die "$instance exists already"
  nix --extra-experimental-features "$features" run "path:$framework_root#dotsteward" -- init \
    --dir "$instance" \
    --remote "$remote" \
    --systems aarch64-darwin \
    --components shell,herdr,claude-code,codex,opencode-pi,vscode \
    --method-platform shell=darwin:nix \
    --method-platform herdr=darwin:nix \
    --method-platform claude-code=darwin:official-binary \
    --method-platform codex=darwin:official-binary \
    --method-platform opencode-pi=darwin:official-binary \
    --method-platform vscode=darwin:app-archive \
    --framework-url "path:$framework_root" \
    --non-interactive
}

publish_instance() {
  git init --quiet --bare --initial-branch=main "$remote"
  git -C "$instance" remote add origin "$remote"
  git -C "$instance" push --quiet --set-upstream origin main
  git -C "$instance" log --oneline -1
}

step "Nix (stage 0, --install-nix-only)" install_nix
nix_profile=/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
[[ -r $nix_profile ]] || die "the Nix daemon profile is missing: $nix_profile"
# The profile script is not written for nounset.
set +u
# shellcheck source=/dev/null
source "$nix_profile"
set -u
step "Machine" machine_facts
step "dotsteward init" init_instance
step "Publish the instance to a local bare remote" publish_instance
step "rebuild --build-only" cli rebuild --profile "$profile" --build-only
step "rebuild --switch" cli rebuild --profile "$profile" --switch
step "login-shell set" cli login-shell set --profile "$profile"
step "e2e" cli e2e --profile "$profile" --keep-going
log "the instance was built, activated and checked end to end on macOS"
