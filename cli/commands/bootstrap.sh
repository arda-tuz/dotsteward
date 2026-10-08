#!/usr/bin/env bash
# summary: Bootstrap stage 1 (run by ./bootstrap.sh once Nix is installed)
#
# The second stage of the instance bootstrap. Stage 0 is the instance's
# ./bootstrap.sh (the framework's template/bootstrap.sh): preflight,
# backups, prerequisites and the verified Nix install, then
# `exec .dotsteward/cli.sh bootstrap --profile P --stage 1`. Stage 1 runs,
# in this order, each through the dotsteward CLI of this framework:
#   1. install --profile P          the system-install phase (fresh mode:
#                                   preflight, the deb transaction, the
#                                   systemInstall, postInstall and forbid
#                                   hooks; adopt mode skips it)
#   2. rebuild --profile P --switch
#   3. login-shell set --profile P
#   4. the desktopApply hooks of the switched generation's manifest (fresh
#      mode; adopt mode skips them with one line)
#   5. e2e --profile P
#   6. the final message
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
(stage 0) once Nix is installed: the system-install phase, rebuild
--switch, the login shell, the desktop apply hooks (fresh mode) and the
E2E checks. Start a bootstrap with ./bootstrap.sh --profile PROFILE.

  --profile PROFILE   the instance's bootstrap profile (profiles.bootstrap)
  --stage 1           the stage to run (internal; stage 0 is ./bootstrap.sh)

Exit status: 0 done, 1 refusal, else the status of the failing step (3:
the adaptive route).
EOF
}

profile=''
stage=''
while (($#)); do
  case $1 in
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

step install --profile "$profile"
step rebuild --profile "$profile" --switch
step login-shell set --profile "$profile"
desktop_apply
step e2e --profile "$profile"
log "bootstrap complete for profile $profile; log out and back in once so the new login shell and desktop session take effect"
