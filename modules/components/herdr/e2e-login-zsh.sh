#!/usr/bin/env bash
# E2E hook of the herdr component (checks.e2e, phase main): an interactive
# login zsh, the shell a terminal opens, finds herdr on PATH. It runs with
# the hook environment (DOTSTEWARD_LIB and the other DOTSTEWARD_* variables)
# and the user's own startup files; stdin is closed so a startup file that
# waits for input cannot hang the check. The last line the shell prints is
# the path: anything a startup file prints comes before it.
# shellcheck source=cli/lib/lib.sh
source "$DOTSTEWARD_LIB/lib.sh"

require_command zsh

found=$(zsh -l -i -c 'whence -p herdr' </dev/null 2>/dev/null | tail -n 1) || found=""
[[ $found == /* ]] || die "herdr is not on PATH in a login zsh"
log "a login zsh finds herdr: $found"
