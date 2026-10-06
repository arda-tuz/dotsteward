# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # the scripts are expanded by the child bash
# cli/lib/stage0.sh carries pre-Nix copies of the library helpers that the
# stage-0 body of preflight and stage-0 itself use (no cli/lib exists before
# Nix). The copies are identical to cli/lib/lib.sh and
# cli/lib/platform-linux.sh, so `dotsteward preflight` and bootstrap.sh
# behave the same; this test keeps them so. stage0.sh itself defines
# functions only.

functions=(
  log warn die current_platform require_safe_identity timestamp_utc ensure_private_dir
  backup_file_private source_nix_daemon cleanup_temp_dir _os_release_unquote os_release_value
)

# definitions LIBRARY...: `declare -f` of every function above after
# sourcing the libraries in a clean bash.
definitions() {
  env DOTSTEWARD_PLATFORM=linux "$BASH" --norc --noprofile -c '
    for library in "$@"; do
      source "$library"
    done
    for name in '"${functions[*]}"'; do
      declare -f "$name" || echo "missing function: $name"
    done
  ' definitions "$@"
}

library=$(definitions "$DS_REPO_ROOT/cli/lib/lib.sh" "$DS_REPO_ROOT/cli/lib/platform-linux.sh")
stage0=$(definitions "$DS_REPO_ROOT/cli/lib/stage0.sh")
assert_not_contains "$library" "missing function" "library functions"
assert_not_contains "$stage0" "missing function" "stage0.sh functions"
assert_eq "$library" "$stage0" "stage0.sh copies of the library helpers"

# Sourcing stage0.sh runs nothing: no output, no variable but its own.
output=$(env -i PATH="$PATH" HOME="$HOME" "$BASH" --norc --noprofile -c '
  before=$(compgen -v | sort)
  source "$1"
  after=$(compgen -v | sort)
  comm -13 <(printf "%s\n" "$before") <(printf "%s\n" "$after") | grep -v -e "^before$" -e "^_$" -e "^PIPESTATUS$" || true
' parity "$DS_REPO_ROOT/cli/lib/stage0.sh" 2>&1)
assert_eq "" "$output" "sourcing stage0.sh defines functions only"
