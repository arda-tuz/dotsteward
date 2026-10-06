# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# home-path precision: a path built on a variable (Nix or shell interpolation)
# is not an absolute home path, while real absolute home paths are still found.
# shellcheck source=tests/privacy/helpers.sh
source "$DS_REPO_ROOT/tests/privacy/helpers.sh"

user=$(rand_word 8)

new_repo repo
cd repo
# shellcheck disable=SC2016 # the dollar signs are literal file content
{
  printf '%s\n' 'src = "${fixture}/home/AGENTS.md";'
  printf '%s\n' 'cp "$out/home/settings.json" .'
  printf '%s\n' 'target=$(pwd)/home/config'
  printf '%s\n' 'HOME=/Users/other ./run'
} >relative.txt
assert_exit 0 scan --tree --redact
assert_eq "[dotsteward] scan clean: 1 files, 0 commits" "$DS_STDOUT"

# Absolute home paths after quotes, '=' or spaces are still findings.
{
  printf 'path = "%s"\n' "$(home_path "$user")"
  printf 'HOME=%s\n' "$(home_path "$user")"
  printf 'cd %s\n' "$(home_path "$user")"
} >absolute.txt
assert_exit 1 scan --tree --redact
assert_eq "3" "$(finding_count)"
