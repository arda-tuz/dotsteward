#!/usr/bin/env bash
# summary: Set, migrate or check the stable login shell of the instance
#
# Port of ensure_stable_login_shell (SPEC 6.2). The login shell is the
# manifest's login_shell ($HOME or ${HOME} expanded at run time; null: the
# instance does not manage it, and every mode succeeds without a change).
# The manifest is the one of --generation, else of the active Home Manager
# generation, else the instance's mirror. A versioned /nix/store path as
# the login shell could be removed by Nix garbage collection, so the
# instance's stable path is used:
#   set      lists the shell in the shells file (the added line is recorded
#            in <state>/current/etc-shells-added-path) and sets it as the
#            login shell; sudo may ask for a password (bootstrap)
#   migrate  only moves a versioned Nix zsh to the stable path; without
#            sudo rights and without a terminal it warns instead (rebuild)
#   check    changes nothing: the shell is executable, listed in the shells
#            file and the user's login shell (e2e)
# The system access goes through the platform layer (platform-<os>.sh).
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
Usage: dotsteward login-shell set|migrate|check --profile PROFILE
                              [--generation PATH]

set makes the instance's login shell (the manifest's login_shell) the login
shell of the user, adding it to the shells file first. migrate moves a
versioned Nix zsh login shell to that stable path and only warns when sudo
would need a password and there is no terminal. check verifies that the
shell is executable, listed in the shells file and the user's login shell.

  --profile PROFILE   a profile of the instance (required)
  --generation PATH   a built Home Manager generation whose manifest names
                      the login shell; default: the active generation, else
                      the instance's manifest mirror

Exit status: 0 done or verified, 1 refusal or failed check, or the status
of a failed system command.
EOF
}

mode=''
profile=''
generation=''
while (($#)); do
  case $1 in
    set | migrate | check)
      [[ -z $mode ]] || die "login-shell: only one of set, migrate or check is allowed"
      mode=$1
      shift
      ;;
    --profile | --generation)
      if (($# < 2)) || [[ -z $2 ]]; then
        die "login-shell: $1 requires a value"
      fi
      if [[ $1 == --profile ]]; then
        profile=$2
      else
        generation=$2
      fi
      shift 2
      ;;
    --profile=*)
      profile=${1#--profile=}
      shift
      ;;
    --generation=*)
      generation=${1#--generation=}
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "login-shell: unknown option: $1" ;;
    *) die "login-shell: unknown subcommand: $1 (expected set, migrate or check)" ;;
  esac
done
[[ -n $mode ]] || die "login-shell: set, migrate or check is required"
[[ -n $profile ]] || die "login-shell: --profile is required"
if [[ -n $generation ]]; then
  [[ -d $generation ]] || die "login-shell: generation not found: $generation"
  generation=$(cd -P -- "$generation" && pwd)
fi

# shellcheck disable=SC2119 # the instance comes from --instance or discovery
config_load
require_profile "$profile"
require_safe_identity
[[ -n $generation ]] || generation=$(skills_active_generation)
methods_manifest_load "$generation"

raw=$(jq -r '.login_shell // empty' <<<"$DS_MANIFEST_JSON")
if [[ -z $raw ]]; then
  log "the instance does not manage the login shell"
  exit 0
fi
# shellcheck disable=SC2016 # the literal text $HOME and ${HOME} is replaced
login_shell=${raw//'${HOME}'/$HOME}
# shellcheck disable=SC2016 # the literal text $HOME and ${HOME} is replaced
login_shell=${login_shell//'$HOME'/$HOME}
[[ $login_shell == /* ]] || die "invalid login shell in the manifest (expected an absolute path): $raw"
for function in platform_login_shell platform_shells_file platform_shells_contains platform_shells_add \
  platform_shells_remove platform_set_login_shell; do
  declare -F "$function" >/dev/null || die "login shell changes are not available on $DS_RUNTIME_PLATFORM"
done

# The library's stable path is the instance's login shell.
stable_zsh_path() {
  printf '%s\n' "$login_shell"
}

case $mode in
  set | migrate)
    ensure_stable_login_shell "$mode" "$profile"
    ;;
  check)
    [[ -x $login_shell && ! -d $login_shell ]] || die "login shell is not executable: $login_shell"
    platform_shells_contains "$login_shell" ||
      die "login shell is not listed in $(platform_shells_file): $login_shell"
    current_shell=$(platform_login_shell "$USER")
    [[ $current_shell == "$login_shell" ]] ||
      die "the login shell of $USER is $current_shell, not $login_shell; run 'dotsteward login-shell set --profile $profile' in a terminal"
    log "login shell ok: $login_shell"
    ;;
esac
