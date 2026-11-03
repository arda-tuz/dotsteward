# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# A reader that stops at its first match never fails a static check. Under
# pipefail, `WRITER | grep -q` fails when grep exits on a match while the
# writer still has output: the writer dies of SIGPIPE and the pipeline's
# status is its 141. The checks read such input whole first, so:
#   - a shell file without a shebang whose "# shellcheck shell=" directive
#     is followed by a line longer than a pipe buffer passes the shell
#     check;
#   - an instance whose [privacy] exemptions name more paths than a pipe
#     buffer holds keeps every exemption in force.
# The fillers are larger than a pipe buffer, so the old readers failed every
# time.
# shellcheck source=tests/static/helpers.sh
source "$DS_REPO_ROOT/tests/static/helpers.sh"

inst=$DS_TEST_ROOT/inst
make_instance "$inst"
cd "$inst"

# --- the shell directive ------------------------------------------------------

{
  printf '# shellcheck shell=bash\n'
  printf '# %s\n' "$(head -c 262144 /dev/zero | tr '\0' x)"
  printf 'printf '\''loaded\\n'\''\n'
} >"$inst/scripts/long-comment.sh"
commit_instance "$inst"
assert_exit 0 static --only shell
assert_not_contains "$DS_STDERR" "has neither a shebang nor"
assert_contains "$DS_STDOUT" "[dotsteward] static checks passed (instance): shell"

# --- privacy exemptions ---------------------------------------------------------

# 45 vendored files with a secret-shaped assignment, each exempted at its
# digest: their paths (about 1950 characters each) fill more than a pipe
# buffer, while the configuration stays small enough for the environment.
deep=vendor
for ((i = 0; i < 8; i++)); do
  deep+=/$(printf '%0240d' "$i")
done
mkdir -p "$inst/$deep"
exemptions=$DS_TEST_ROOT/exemptions.toml
: >"$exemptions"
for ((i = 1; i <= 45; i++)); do
  file=$deep/client-$i.py
  printf '%s = os.environ["EXAMPLE_KEY"]\n' "api""_key" >"$inst/$file"
  printf '\n[[privacy.exemptions]]\npath = "%s"\nrule = "secret-assignment"\nsha256 = "%s"\nreason = "reads the key from the environment"\n' \
    "$file" "$(sha256_of "$inst/$file")" >>"$exemptions"
done
{
  printf '\n[privacy]\n'
  cat "$exemptions"
} >>"$inst/workstation.toml"
commit_instance "$inst"
assert_exit 0 static --only privacy
assert_not_contains "$DS_STDERR" "no longer matches"
assert_contains "$DS_STDOUT" "[dotsteward] 45 findings exempted by [privacy] exemptions"
assert_contains "$DS_STDOUT" "[dotsteward] scan clean:"
