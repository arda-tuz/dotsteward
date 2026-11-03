#!/usr/bin/env bash
# E2E hook of the codex component (checks.e2e codex-login-path, phase main),
# declared with the shell component, for its profiles. It runs with the hook
# environment and asks an interactive login zsh, the shell a terminal opens,
# for every codex on its PATH in order (`whence -a -p`), started from the
# user's PATH (user_run: without the CLI's own toolchain) with stdin closed.
# The expected codex is options.expectedPath of [components.codex] (a home
# path ~/... or an absolute path), else, with the official-binary method,
# its install destination ~/.local/bin/codex:
#   - it must be an executable file;
#   - the first codex on PATH must be that file (a link to it counts);
#     another copy earlier on PATH fails the hook, which names it.
# Without an expected location (the external method without expectedPath)
# the hook reports more than one codex on PATH as a warning and passes.
set -Eeuo pipefail

[[ -n ${DOTSTEWARD_LIB:-} && -n ${DOTSTEWARD_INSTANCE:-} ]] || {
  printf '[dotsteward] ERROR: the codex E2E hook runs from dotsteward e2e (DOTSTEWARD_LIB and DOTSTEWARD_INSTANCE are not set)\n' >&2
  exit 1
}

# shellcheck source=cli/lib/lib.sh
source "$DOTSTEWARD_LIB/lib.sh"
# shellcheck source=cli/lib/config.sh
source "$DOTSTEWARD_LIB/config.sh"

config_load "$DOTSTEWARD_INSTANCE"

component=${DOTSTEWARD_COMPONENT:-codex}

require_command zsh

# shellcheck disable=SC2016 # a jq program: $component is a jq variable
expected=$(config_query --arg component "$component" '.components[$component].options.expectedPath // empty | strings')
method=${DS_COMPONENT_METHOD[$component]:-official-binary}
case $expected in
  \~/*) expected=$HOME/${expected#\~/} ;;
  '')
    # install.official-binary.dest of default.nix: ~/.local/bin/codex.
    [[ $method != official-binary ]] || expected=$HOME/.local/bin/codex
    ;;
esac

# Every codex of the login shell, in PATH order, each file once. The lines
# after the marker are the answer: a startup file may print before it.
marker=dotsteward-codex-login-path
output=$(user_run zsh -l -i -c "print -r -- $marker; whence -a -p codex" </dev/null 2>/dev/null) || output=''
found=()
listed=0
while IFS= read -r line; do
  if ((!listed)); then
    [[ $line != "$marker" ]] || listed=1
    continue
  fi
  [[ $line == /* && -x $line ]] || continue
  seen=0
  for path in "${found[@]}"; do
    [[ ! $path -ef $line ]] || seen=1
  done
  ((seen)) || found+=("$line")
done <<<"$output"

if [[ -z $expected ]]; then
  if ((${#found[@]} > 1)); then
    warn "a login zsh finds more than one codex: it runs ${found[0]}, then $(printf '%s, ' "${found[@]:1}" | sed 's/, $//'); set options.expectedPath of [components.$component] to require one"
  elif ((${#found[@]} == 1)); then
    log "a login zsh runs codex from ${found[0]}"
  fi
  exit 0
fi

[[ -f $expected && -x $expected ]] || die "the expected codex $expected is not an executable file"
((${#found[@]})) || die "codex is not on PATH in a login zsh (expected $expected)"
[[ ${found[0]} -ef $expected ]] ||
  die "a login zsh runs codex from ${found[0]}, which shadows $expected; remove that copy or put $(dirname -- "$expected") before $(dirname -- "${found[0]}") on PATH"
log "a login zsh runs codex from ${found[0]}"
