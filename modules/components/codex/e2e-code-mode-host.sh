#!/usr/bin/env bash
# E2E hook of the codex component (checks.e2e codex-code-mode-host, phase main),
# declared with the official-binary method. From 0.144.0 on Codex runs Code
# Mode, and with it apply_patch, through codex-code-mode-host, which it starts
# from the directory of its resolved executable; a session without the file
# cannot edit anything and says "failed to spawn code-mode host <path>".
#   - a codex older than that needs no helper;
#   - a codex that needs it must have an executable file at that path, and the
#     file must start (--help; the helper has no --version);
#   - a codex at another path than the method's destination is not this
#     method's and is only reported.
# Without the standalone package, the sandbox looks for a system bwrap and
# searches for a system rg; a missing one is a warning (README.md, "The
# helper"). The hook needs neither a network nor an account.
set -Eeuo pipefail

[[ -n ${DOTSTEWARD_LIB:-} && -n ${DOTSTEWARD_INSTANCE:-} ]] || {
  printf '[dotsteward] ERROR: the codex E2E hook runs from dotsteward e2e (DOTSTEWARD_LIB and DOTSTEWARD_INSTANCE are not set)\n' >&2
  exit 1
}

# shellcheck source=cli/lib/lib.sh
source "$DOTSTEWARD_LIB/lib.sh"
# shellcheck source=cli/lib/config.sh
source "$DOTSTEWARD_LIB/config.sh"
# shellcheck source=cli/lib/methods.sh
source "$DOTSTEWARD_LIB/methods.sh"

config_load "$DOTSTEWARD_INSTANCE"
# shellcheck disable=SC2119 # no generation: the mirror of the instance
methods_manifest_load

component=${DOTSTEWARD_COMPONENT:-codex}
profile=${DOTSTEWARD_PROFILE:-$DS_PROFILES_DEFAULT}

methods_check "$component" "$profile" || die "$METHODS_DETAIL"

# An older CLI runs this hook with its own library (docs/component-contract.md,
# "DOTSTEWARD_LIB"): the method of that library knows no companions either.
if ! declare -F methods_official_binary_companions >/dev/null; then
  log "the library of this CLI cannot read the companions of $component; the next upgrade checks them"
  exit 0
fi

# on_user_path COMMAND: COMMAND is on the PATH of the user, without the CLI's
# own toolchain.
on_user_path() {
  PATH=$(user_path) command -v -- "$1" >/dev/null 2>&1
}

while IFS=$'\t' read -r state first second; do
  case $state in
    foreign)
      log "codex at $first is not the one this method installs; nothing to check for $second"
      ;;
    not-needed)
      log "codex $first does not need $second"
      ;;
    needed)
      # methods_check saw an executable file at this path: it must also start.
      exit_code=0
      user_run "$second" --help </dev/null >/dev/null 2>&1 || exit_code=$?
      ((exit_code == 0)) || die "$second cannot start (exit $exit_code)"
      log "codex $first starts $second"
      directory=${second%/*}
      package=${directory%/*}
      if [[ $(current_platform) == linux ]] && ! on_user_path bwrap &&
        [[ ! -x $directory/codex-resources/bwrap && ! -x $package/codex-resources/bwrap ]]; then
        warn "no bwrap on PATH and no codex-resources/bwrap next to codex: sandboxed commands fail until bubblewrap is installed"
      fi
      if ! on_user_path rg && [[ ! -x $package/codex-path/rg ]]; then
        warn "no rg on PATH and no codex-path/rg next to codex: install ripgrep"
      fi
      ;;
  esac
done < <(methods_official_binary_companions "$component")
