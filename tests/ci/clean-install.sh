#!/usr/bin/env bash
# Clean-install test on a fresh GitHub-hosted ubuntu-24.04 runner (SPEC
# 12.5): a new instance with every catalog component, installed the way a
# new machine is (the fresh profile through stage 0), activated in the
# runner's own home, checked end to end, carried to a second home through
# the settings buffer and rolled back.
#
# Usage: tests/ci/clean-install.sh
#
# Steps, the first failure stops the run:
#   1. the pinned Nix through the framework's stage 0 (template/bootstrap.sh
#      --install-nix-only, the path of `dotsteward-init` before an instance
#      exists), with DOTSTEWARD_ASSUME_YES=1;
#   2. `dotsteward init` from this checkout (`nix run path:<checkout>#dotsteward`)
#      into ~/workstation: all six catalog components on their default
#      Linux methods, the framework input path:<checkout> (a shallow
#      checkout cannot be a git+file input) and a local bare repository as
#      instance.remote, to which the instance is then pushed;
#   3. the instance's ./bootstrap.sh --profile fresh with
#      DOTSTEWARD_ASSUME_YES=1: preflight, backups, prerequisites, the Nix
#      version check, then stage 1 (system install, rebuild --switch, login
#      shell, desktop apply hooks, e2e);
#   4. rebuild --switch again over the existing generation, then
#      e2e --keep-going, so a single run reports every failing check;
#   5. the settings round trip: a Claude Code setting is tracked, published
#      to the bare remote, applied, edited, flushed and published again;
#      a second home of the same runner user ($RUNNER_TEMP/home2, with
#      HOME and XDG_STATE_HOME below it) clones the instance, activates
#      the adopt profile there (Home Manager homeDirectory = that
#      directory, the real user name) and gets the edited value; the
#      real home's Home Manager profile is checked to be untouched;
#   6. rollback --latest: the plan (--dry-run --json) must remove the
#      managed links (no Home Manager before the first install), then
#      --apply; afterwards the managed links are gone, the login shell is
#      the one the runner started with and the shells-file line the
#      bootstrap added is gone.
# On a failure the redacted `dotsteward doctor` report and the records of
# <state>/current are printed.
#
# It installs packages with sudo and activates Home Manager in the real
# home, so it runs only on a GitHub Actions ubuntu-24.04 x86_64 runner
# (GITHUB_ACTIONS=true); .github/workflows/clean-install.yml runs it.
set -Eeuo pipefail

die() {
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then
    printf '::error title=clean-install::%s\n' "$*"
  fi
  printf '[dotsteward] ERROR: clean-install: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[dotsteward] clean-install: %s\n' "$*" >&2
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
(($# == 0)) || die "usage: clean-install.sh"

[[ ${GITHUB_ACTIONS:-} == true ]] || die "runs only on GitHub Actions runners: it installs packages and activates the real home"
[[ $(uname -s) == Linux ]] || die "runs only on Linux runners"
[[ $(uname -m) == x86_64 ]] || die "runs only on x86_64 runners"
# shellcheck source=/dev/null
os_id=$(. /etc/os-release && printf '%s %s' "${ID:-}" "${VERSION_ID:-}")
[[ $os_id == 'ubuntu 24.04' ]] || die "runs only on ubuntu-24.04 runners (found: $os_id)"
[[ -n ${RUNNER_TEMP:-} && -d $RUNNER_TEMP ]] || die "RUNNER_TEMP is not a directory"
[[ -n ${HOME:-} && -d $HOME ]] || die "HOME is not a directory"

framework_root=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
[[ -f $framework_root/flake.nix && -f $framework_root/template/bootstrap.sh ]] ||
  die "not a dotsteward checkout: $framework_root"

USER=${USER:-$(id -un)}
export USER
fresh_profile=fresh
adopt_profile=workstation
instance=$HOME/workstation
remote=$RUNNER_TEMP/workstation.git
home2=$RUNNER_TEMP/home2
state_root=${XDG_STATE_HOME:-$HOME/.local/state}/dotsteward
features='nix-command flakes'
# The tracked setting of the round trip: a scalar key of the claude-settings
# target (~/.claude/settings.json, created when missing).
setting_id=ci-round
setting_target=claude-settings
setting_key=cleanupPeriodDays
setting_first=30
setting_edited=45
plan=$RUNNER_TEMP/rollback-plan.json

# The commits of `dotsteward init` and of the settings round use the user's
# own git identity; a runner has none.
export GIT_AUTHOR_NAME=dotsteward-ci GIT_AUTHOR_EMAIL=dotsteward-ci@users.noreply.github.com
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL

# The login shell the runner started with: rollback must restore it.
original_shell=$(getent passwd "$USER" | cut -d: -f7)
[[ -n $original_shell ]] || die "cannot read the login shell of $USER"

current_step=''

# on_exit: after a failure, the failing step, the redacted health report of
# the instance (when it exists by then) and the records of rebuild.
on_exit() {
  local status=$?
  ((status != 0)) || return 0
  if [[ -n $current_step ]]; then
    printf '::endgroup::\n'
    printf '::error title=clean-install::%s failed (exit %s)\n' "$current_step" "$status"
  fi
  if [[ -x $instance/.dotsteward/cli.sh ]]; then
    printf '::group::%s\n' "dotsteward doctor --redact"
    "$instance/.dotsteward/cli.sh" doctor --redact >&2 || true
    printf '::endgroup::\n'
  fi
  if [[ -d $state_root/current ]]; then
    printf '::group::%s\n' "records of $state_root/current"
    find "$state_root/current" -maxdepth 1 -type f -size -8k -print -exec cat {} \; >&2 || true
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

# cli_home2 COMMAND [ARG...]: the CLI of the second home's clone, run as
# the same user with HOME and XDG_STATE_HOME below the second home. The
# Nix download cache stays the runner's, so the locked inputs are not
# fetched twice.
cli_home2() {
  env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u DOTSTEWARD_STATE_ROOT \
    HOME="$home2" XDG_STATE_HOME="$home2/.local/state" \
    XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}" \
    "$home2/workstation/.dotsteward/cli.sh" "$@"
}

# hm_profile HOME: the Home Manager profile link of HOME's state directory.
hm_profile() {
  printf '%s/.local/state/nix/profiles/home-manager\n' "$1"
}

source_nix_profile() {
  local nix_profile=/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  [[ -r $nix_profile ]] || die "the Nix daemon profile is missing: $nix_profile"
  # The profile script is not written for nounset.
  set +u
  # shellcheck source=/dev/null
  source "$nix_profile"
  set -u
}

install_nix() {
  DOTSTEWARD_ASSUME_YES=1 bash "$framework_root/template/bootstrap.sh" --install-nix-only
}

machine_facts() {
  # shellcheck source=/dev/null
  printf '%s on %s, user %s, home %s, login shell %s\n' \
    "$(. /etc/os-release && printf '%s' "$PRETTY_NAME")" "$(uname -m)" "$USER" "$HOME" "$original_shell"
  nix --version
  df -h / "$RUNNER_TEMP"
}

init_instance() {
  [[ ! -e $instance ]] || die "$instance exists already"
  nix --extra-experimental-features "$features" run "path:$framework_root#dotsteward" -- init \
    --dir "$instance" \
    --remote "$remote" \
    --components shell,herdr,claude-code,codex,opencode-pi,vscode \
    --profiles "$adopt_profile,$fresh_profile" \
    --framework-url "path:$framework_root" \
    --non-interactive
}

publish_instance() {
  git init --quiet --bare --initial-branch=main "$remote"
  git -C "$instance" remote add origin "$remote"
  git -C "$instance" push --quiet --set-upstream origin main
  git -C "$instance" log --oneline -1
}

bootstrap_instance() {
  # Both homes keep their Home Manager profile in their own state
  # directory, as Nix 2.14+ lays it out: with only the global per-user
  # directory, the activation in the second home would move this home's
  # profile there (Home Manager's profile migration).
  mkdir -p "$(dirname -- "$(hm_profile "$HOME")")"
  (cd "$instance" && DOTSTEWARD_ASSUME_YES=1 ./bootstrap.sh --profile "$fresh_profile")
}

# set_live_setting VALUE: the tracked key in the live settings file, the
# other keys kept.
set_live_setting() {
  local file=$HOME/.claude/settings.json tmp
  mkdir -p "$HOME/.claude"
  [[ -s $file ]] || printf '{}\n' >"$file"
  tmp=$(mktemp "$file.XXXXXX")
  jq --argjson value "$1" --arg key "$setting_key" '.[$key] = $value' "$file" >"$tmp"
  mv -f -- "$tmp" "$file"
}

# publish MESSAGE: commits the settings buffer and pushes it; a buffer
# without a change fails the commit.
publish() {
  git -C "$instance" add -A -- local-maintained-files
  git -C "$instance" commit --quiet -m "$1"
  git -C "$instance" push --quiet origin main
  git -C "$instance" log --oneline -1
}

settings_round_first_home() {
  set_live_setting "$setting_first"
  cli settings track --id "$setting_id" --target "$setting_target" --key "$setting_key"
  publish "chore(settings): track $setting_key"
  # The published entry becomes this machine's base.
  cli settings apply
  set_live_setting "$setting_edited"
  cli settings flush
  publish "chore(settings): set $setting_key to $setting_edited"
  cli settings verify
  cli settings status
}

settings_round_second_home() {
  local profile_link before after value
  profile_link=$(hm_profile "$HOME")
  [[ -L $profile_link ]] ||
    die "the Home Manager profile of $HOME is not $profile_link; a second activation could move it"
  before=$(readlink -- "$profile_link")
  [[ ! -e $home2 ]] || die "$home2 exists already"
  mkdir -p "$(dirname -- "$(hm_profile "$home2")")"
  git clone --quiet "$remote" "$home2/workstation"
  cli_home2 rebuild --profile "$adopt_profile" --switch
  [[ -L $(hm_profile "$home2") ]] || die "the second home has no Home Manager profile of its own"
  cli_home2 settings apply
  cli_home2 settings verify
  value=$(jq -r --arg key "$setting_key" '.[$key]' "$home2/.claude/settings.json")
  [[ $value == "$setting_edited" ]] ||
    die "the second home has $setting_key = $value, expected $setting_edited"
  after=$(readlink -- "$profile_link")
  [[ $after == "$before" ]] ||
    die "the activation in the second home changed the Home Manager profile of $HOME ($before -> $after)"
  log "the second home got $setting_key = $value; the first home's profile stayed $before"
}

rollback_dry_run() {
  local link count
  cli rollback --latest --dry-run --json >"$plan"
  jq . "$plan"
  jq -e '.previous_generation == "ABSENT"' "$plan" >/dev/null ||
    die "a clean machine must record no Home Manager generation before the first install"
  jq -e '.steps[] | select(.id == "home-manager") | .action == "remove-links"' "$plan" >/dev/null ||
    die "the rollback plan does not remove the managed links"
  count=$(jq '[.steps[] | select(.id == "home-manager") | .links[]] | length' "$plan")
  ((count > 0)) || die "the rollback plan lists no managed links"
  while IFS= read -r link; do
    [[ -L $link ]] || die "the managed link $link is missing before the rollback"
  done < <(jq -r '.steps[] | select(.id == "home-manager") | .links[]' "$plan")
}

rollback_apply() {
  cli rollback --latest --apply
}

rollback_assertions() {
  local link action shell line file
  while IFS= read -r link; do
    [[ ! -L $link ]] || die "the managed link $link is still there after the rollback"
  done < <(jq -r '.steps[] | select(.id == "home-manager") | .links[]' "$plan")
  shell=$(getent passwd "$USER" | cut -d: -f7)
  action=$(jq -r '.steps[] | select(.id == "login-shell") | .action' "$plan")
  if [[ $action == set ]]; then
    [[ $shell == "$(jq -r '.steps[] | select(.id == "login-shell") | .shell' "$plan")" ]] ||
      die "the login shell is $shell, not the one of the rollback plan"
  fi
  [[ $shell == "$original_shell" ]] ||
    die "the login shell is $shell, the runner started with $original_shell"
  action=$(jq -r '.steps[] | select(.id == "shells-line") | .action' "$plan")
  if [[ $action == remove ]]; then
    line=$(jq -r '.steps[] | select(.id == "shells-line") | .path' "$plan")
    file=$(jq -r '.steps[] | select(.id == "shells-line") | .file' "$plan")
    if grep -qxF -- "$line" "$file"; then
      die "$file still lists $line"
    fi
  fi
  log "managed links gone, login shell $shell, shells file restored"
}

step "Nix (stage 0, --install-nix-only)" install_nix
source_nix_profile
step "Machine" machine_facts
step "dotsteward init" init_instance
step "Publish the instance to a local bare remote" publish_instance
step "./bootstrap.sh --profile $fresh_profile (stage 0 and stage 1)" bootstrap_instance
step "rebuild --switch over the existing generation" cli rebuild --profile "$fresh_profile" --switch
step "e2e" cli e2e --profile "$fresh_profile" --keep-going
step "Settings round: track, publish, apply, edit, flush, publish" settings_round_first_home
step "Settings round: activation and apply in a second home" settings_round_second_home
step "rollback --latest --dry-run --json" rollback_dry_run
step "rollback --latest --apply" rollback_apply
step "After the rollback" rollback_assertions
log "the instance was bootstrapped, checked end to end, carried to a second home and rolled back"
