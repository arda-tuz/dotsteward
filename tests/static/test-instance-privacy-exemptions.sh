# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# shellcheck disable=SC2016 # fixture text with a literal $ is written on purpose
# Instance privacy exemptions: a [[privacy.exemptions]] entry (path, rule,
# sha256, reason) silences one rule on one file while the file still has
# that SHA-256, for third-party text that matches a generic rule without
# holding a secret (vendored code that reads a key from the environment, a
# file name that matches a forbidden-path glob). Only the generic secret
# rules and forbidden-path can be exempted, never a denylist term or a file
# rule. An exemption that no longer applies (another digest, a missing file,
# no finding left to silence) fails the scan, so it is reviewed again.
# shellcheck source=tests/static/helpers.sh
source "$DS_REPO_ROOT/tests/static/helpers.sh"

inst=$DS_TEST_ROOT/inst
make_instance "$inst"
mkdir -p "$inst/vendor/example" "$HOME/private"
printf '%s = os.environ["EXAMPLE_KEY"]\n' "api""_key" >"$inst/vendor/example/client.py"
printf 'notes\n' >"$inst/vendor/example/plan-implementation.md"
printf '# private terms\n%s\n' "secretproject" >"$HOME/private/denylist.txt"
client_sha=$(sha256sum "$inst/vendor/example/client.py" | cut -d ' ' -f 1)
plan_sha=$(sha256sum "$inst/vendor/example/plan-implementation.md" | cut -d ' ' -f 1)

# privacy_section [EXEMPTIONS_TOML]: the [privacy] table with a forbidden
# *implementation.md glob, the denylist and the given exemptions.
privacy_section() {
  awk '/^\[privacy\]$/ { exit } { print }' "$inst/workstation.toml" >"$inst/workstation.toml.new"
  mv -- "$inst/workstation.toml.new" "$inst/workstation.toml"
  cat >>"$inst/workstation.toml" <<TOML
[privacy]
forbidden_paths = ["*implementation.md"]
denylist = "~/private/denylist.txt"
${1:-}
TOML
}

privacy_section
commit_instance "$inst"
cd "$inst"

# Without exemptions both files are findings.
assert_exit 1 static --only privacy
assert_contains "$DS_STDOUT" "secret-assignment vendor/example/client.py:1"
assert_contains "$DS_STDOUT" "forbidden-path vendor/example/plan-implementation.md (path)"

# Exempted at their digests: the scan is clean and names the exemptions.
privacy_section "
[[privacy.exemptions]]
path = \"vendor/example/client.py\"
rule = \"secret-assignment\"
sha256 = \"$client_sha\"
reason = \"reads the key from the environment\"

[[privacy.exemptions]]
path = \"vendor/example/plan-implementation.md\"
rule = \"forbidden-path\"
sha256 = \"$plan_sha\"
reason = \"upstream documentation, not a planning note\""
assert_exit 0 static --only privacy
assert_contains "$DS_STDOUT" "[dotsteward] scan clean:"
assert_contains "$DS_STDOUT" "[dotsteward] 2 findings exempted by [privacy] exemptions"

# An exemption covers its rule only: another rule on the same file still fires.
printf 'token %s\n' "$(fake_secret 'gh''p_' 30)" >>"$inst/vendor/example/client.py"
assert_exit 1 static --only privacy
assert_contains "$DS_STDOUT" "secret-github-token vendor/example/client.py:2"

# A changed file loses its exemption: the finding returns and the stale
# exemption is named.
printf '%s = os.environ["OTHER_KEY"]\n' "api""_key" >"$inst/vendor/example/client.py"
assert_exit 1 static --only privacy
assert_contains "$DS_STDOUT" "secret-assignment vendor/example/client.py:1"
assert_contains "$DS_STDERR" "privacy exemption 1 (vendor/example/client.py, secret-assignment) no longer matches: the file's SHA-256 is $(sha256sum "$inst/vendor/example/client.py" | cut -d ' ' -f 1)"

# A missing file, and an exemption with nothing left to silence, are stale.
printf '%s = os.environ["EXAMPLE_KEY"]\n' "api""_key" >"$inst/vendor/example/client.py"
rm "$inst/vendor/example/plan-implementation.md"
assert_exit 1 static --only privacy
assert_contains "$DS_STDERR" "privacy exemption 2 (vendor/example/plan-implementation.md, forbidden-path) no longer matches: the file is not in the tree"
printf 'notes\n' >"$inst/vendor/example/plan-implementation.md"
assert_exit 0 static --only privacy
privacy_section "
[[privacy.exemptions]]
path = \"vendor/example/client.py\"
rule = \"secret-aws-key\"
sha256 = \"$client_sha\"
reason = \"nothing to silence\""
rm "$inst/vendor/example/plan-implementation.md"
assert_exit 1 static --only privacy
assert_contains "$DS_STDOUT" "secret-assignment vendor/example/client.py:1"
assert_contains "$DS_STDERR" "privacy exemption 1 (vendor/example/client.py, secret-aws-key) silences no finding; remove it"

# Denylist terms and file rules can never be exempted.
for rule in denylist:2 file-rule:1 home-path; do
  privacy_section "
[[privacy.exemptions]]
path = \"vendor/example/client.py\"
rule = \"$rule\"
sha256 = \"$client_sha\"
reason = \"never allowed\""
  assert_exit 1 static --only privacy
  assert_contains "$DS_STDERR" "privacy exemption 1: rule $rule cannot be exempted (allowed: secret-private-key, secret-aws-key, secret-github-token, secret-github-pat, secret-google-key, secret-sk-key, secret-assignment, forbidden-path)"
done

# The digest is 64 hexadecimal digits and the reason is required.
privacy_section "
[[privacy.exemptions]]
path = \"vendor/example/client.py\"
rule = \"secret-assignment\"
sha256 = \"abc\"
reason = \"x\""
assert_exit 1 static --only privacy
assert_contains "$DS_STDERR" "abc"
