# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# The framework checkout itself passes the generic scan (git-visible files in
# a checkout, every file of the source in the Nix sandbox), and the scanner's
# own pattern table is the only exempt block.
# shellcheck source=tests/privacy/helpers.sh
source "$DS_REPO_ROOT/tests/privacy/helpers.sh"

cd "$DS_REPO_ROOT"
assert_exit 0 scan --tree --redact
[[ $DS_STDOUT =~ ^\[dotsteward\]\ scan\ clean:\ [1-9][0-9]*\ files,\ 0\ commits$ ]] ||
  ds_fail "unexpected scan output: $DS_STDOUT"

# Exactly one pattern block, in cli/lib/privacy.sh only.
markers=$(grep -rlE '^# dotsteward:patterns:(begin|end)$' cli tests privacy nix lib 2>/dev/null || true)
assert_eq "cli/lib/privacy.sh" "$markers"
assert_eq 1 "$(grep -c '^# dotsteward:patterns:begin$' cli/lib/privacy.sh)"
assert_eq 1 "$(grep -c '^# dotsteward:patterns:end$' cli/lib/privacy.sh)"

# The shipped allowlist and policy are plain ASCII text ending with a newline.
for file in privacy/policy.toml privacy/allowlist.txt cli/lib/privacy.sh cli/commands/scan.sh; do
  if LC_ALL=C grep -q '[^[:print:][:space:]]' "$file"; then
    ds_fail "$file contains non-ASCII bytes"
  fi
  [[ -z $(tail -c 1 "$file") ]] || ds_fail "$file does not end with a newline"
done
