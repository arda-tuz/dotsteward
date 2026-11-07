#!/usr/bin/env bash
# summary: Bootstrap stage 1 (run by ./bootstrap.sh once Nix is installed)
#
# The second stage of the instance bootstrap. Stage 0 is the instance's
# ./bootstrap.sh (the framework's template/bootstrap.sh): preflight,
# backups, prerequisites and the verified Nix install, then
# `exec .dotsteward/cli.sh bootstrap --profile P --stage 1`. Stage 1 runs,
# in this order, each through the dotsteward CLI of this framework:
#   1. host init --profile P        the name of this machine, in the state root
#                                   only: nothing is committed. A terminal
#                                   asks. Without one the name comes from
#                                   DOTSTEWARD_MACHINE or the host name
#                                   (DOTSTEWARD_ASSUME_YES=1), a registered name
#                                   with DOTSTEWARD_MACHINE_REUSE=1, else stage 1
#                                   stops when hosts/ names machines, and goes
#                                   on without a name when it does not
#   2. install --profile P          the system-install phase (fresh mode:
#                                   preflight, the deb transaction, the
#                                   systemInstall, postInstall and forbid
#                                   hooks; adopt mode skips it)
#   3. rebuild --profile P --switch
#   4. login-shell set --profile P
#   5. the desktopApply hooks of the switched generation's manifest (fresh
#      mode; adopt mode skips them with one line)
#   6. e2e --profile P
#   7. host publish                 hosts/<name>.toml to the remote, when the
#                                   machine has a name; no failure stops stage
#                                   1 here: it says so and the next `host
#                                   publish` works it out again
#   8. the final message
# The first failing step stops stage 1 with its exit status (3 from the
# system-install phase is the adaptive route). P must be profiles.bootstrap.
set -Eeuo pipefail

# shellcheck source=cli/lib/lib.sh
source "$DOTSTEWARD_LIB/lib.sh"
# shellcheck source=cli/lib/config.sh
source "$DOTSTEWARD_LIB/config.sh"
# shellcheck source=cli/lib/methods.sh
source "$DOTSTEWARD_LIB/methods.sh"
# shellcheck source=cli/lib/skills.sh
source "$DOTSTEWARD_LIB/skills.sh"

usage() {
  cat <<'EOF'
Usage: dotsteward bootstrap --profile PROFILE --stage 1

Stage 1 of a fresh-machine bootstrap, run by the instance's ./bootstrap.sh
(stage 0) once Nix is installed: the name of this machine, the
system-install phase, rebuild --switch, the login shell, the desktop apply
hooks (fresh mode), the E2E checks and the host file of this machine. Start a
bootstrap with ./bootstrap.sh --profile PROFILE.

  --profile PROFILE   the instance's bootstrap profile (profiles.bootstrap)
  --stage 1           the stage to run (internal; stage 0 is ./bootstrap.sh)

Exit status: 0 done, 1 refusal, else the status of the failing step (3:
the adaptive route).
EOF
}

profile=''
stage=''
under_lock=''
while (($#)); do
  case $1 in
    --under-lock) # internal: the process above holds the lock for this one
      under_lock=1
      shift
      ;;
    --profile | --stage)
      if (($# < 2)) || [[ -z $2 ]]; then
        die "bootstrap: $1 requires a value"
      fi
      if [[ $1 == --profile ]]; then
        profile=$2
      else
        stage=$2
      fi
      shift 2
      ;;
    --profile=*)
      profile=${1#--profile=}
      [[ -n $profile ]] || die "bootstrap: --profile requires a value"
      shift
      ;;
    --stage=*)
      stage=${1#--stage=}
      [[ -n $stage ]] || die "bootstrap: --stage requires a value"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "bootstrap: unknown option: $1" ;;
  esac
done
[[ -n $profile ]] || die "bootstrap: --profile is required"

# shellcheck disable=SC2119 # the instance comes from --instance or discovery
config_load
if [[ -z $stage ]]; then
  die "bootstrap: stage 0 is the instance's ./bootstrap.sh; run './bootstrap.sh --profile $profile' in $DS_INSTANCE_ROOT (--stage 1 is internal)"
fi
[[ $stage == 1 ]] || die "bootstrap: unsupported stage: $stage (only stage 1 runs in the CLI)"
require_profile "$profile"
[[ $profile == "$DS_PROFILES_BOOTSTRAP" ]] ||
  die "bootstrap: --profile must be the bootstrap profile $DS_PROFILES_BOOTSTRAP (profiles.bootstrap), not $profile"
require_safe_identity
mode=${DS_PROFILE_MODE[$profile]}

# Stage 1 holds the instance lock, so a second bootstrap or an upgrade is refused
# until it ends: it runs itself again under the lock. An argument says so, since
# an environment variable would reach every process started under this one.
if [[ -z $under_lock ]]; then
  lock_status=0
  ds_internal lock run --holder bootstrap --state-root "$(state_root)" -- \
    "$BASH" "${BASH_SOURCE[0]}" --under-lock --profile "$profile" --stage "$stage" || lock_status=$?
  exit "$lock_status"
fi

dotsteward=("$DOTSTEWARD_FRAMEWORK_ROOT/cli/dotsteward" --instance "$DS_INSTANCE_ROOT")

# step COMMAND [ARG...]: dotsteward COMMAND ARG...; a failure stops stage 1
# with its status. Standard input stays the terminal (sudo and apt prompt).
step() {
  local status=0
  "${dotsteward[@]}" "$@" || status=$?
  if ((status != 0)); then
    printf '[dotsteward] ERROR: bootstrap stopped: dotsteward %s failed (exit %s)\n' "$1" "$status" >&2
    exit "$status"
  fi
}

# desktop_apply: the desktopApply hooks of the active generation (the one
# rebuild just switched to), every script checked before the first runs.
desktop_apply() {
  local generation hooks_text hook status component name
  local -a hooks=()
  if [[ $mode == adopt ]]; then
    log "$profile (adopt mode): desktop apply skipped"
    return 0
  fi
  generation=$(skills_active_generation)
  methods_manifest_load "$generation"
  hooks_text=$(methods_hooks desktop_apply "$profile")
  mapfile -t hooks < <(grep -v '^$' <<<"$hooks_text" || true)
  for hook in "${hooks[@]}"; do
    methods_hook_path "$hook" >/dev/null
  done
  for hook in "${hooks[@]}"; do
    status=0
    methods_run_hook "$hook" "$profile" 0 || status=$?
    if ((status != 0)); then
      component=$(jq -r '.component' <<<"$hook")
      name=$(jq -r '.name' <<<"$hook")
      printf '[dotsteward] ERROR: component %s hook %s failed (exit %s)\n' "$component" "$name" "$status" >&2
      exit "$status"
    fi
  done
}

# name_machine: the name of this machine comes first. With nobody to ask and no name
# to take, an instance whose hosts/ names no machine goes on as it always did.
name_machine() {
  if [[ -z $DS_MACHINE_NAME && ! -t 0 && ${DOTSTEWARD_ASSUME_YES:-0} != 1 ]] &&
    ! compgen -G "$DS_INSTANCE_ROOT/hosts/*.toml" >/dev/null; then
    log "this machine stays without a name for now; 'dotsteward host init --name NAME' names it"
    return 0
  fi
  step host init --profile "$profile"
}

# publish_machine: tries to bring the host file to the remote. Without a network or a
# login nothing is lost, so nothing here stops the bootstrap.
publish_machine() {
  local status=0
  [[ -n ${DOTSTEWARD_MACHINE:-} || -f $(state_root)/machine.json ]] || return 0
  "${dotsteward[@]}" host publish || status=$?
  ((status == 0)) ||
    warn "the host file of this machine is not on the remote yet (exit $status); 'dotsteward host publish' tries again"
}

name_machine
step install --profile "$profile"
step rebuild --profile "$profile" --switch
step login-shell set --profile "$profile"
desktop_apply
step e2e --profile "$profile"
publish_machine
log "bootstrap complete for profile $profile; log out and back in once so the new login shell and desktop session take effect"
