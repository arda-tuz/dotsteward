# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # Nix expressions in single quotes
# The contract of install.deb.aptSources: a vendor APT repository with its
# signing key, pinned by the full primary key fingerprint. Optional fields
# take their defaults; a name that is not a plain file name, a URL that is
# not HTTPS or a fingerprint that is not 40 upper-case hex digits is
# refused at evaluation.
# shellcheck source=tests/nix/core/helpers.sh
source "$DS_REPO_ROOT/tests/nix/core/helpers.sh"

fpr=0123456789ABCDEF0123456789ABCDEF01234567
# sources_of SOURCE: the evaluated aptSources of example-app with SOURCE.
sources_of() {
  printf '(homeOf { modules = componentModules ++ [ { dotsteward.components.example-app.install.deb.aptSources = [ (%s) ]; } ]; }).dotsteward.components.example-app.install.deb.aptSources' "$1"
}
source_with() {
  printf '{ name = "example-vendor"; uri = "https://apt.example.invalid/ubuntu"; suites = [ "{codename}" ]; keyUrl = "https://apt.example.invalid/gpg"; keyFingerprint = "%s"; } // %s' "$fpr" "$1"
}

assert_core_eq '[]' '(homeOf { modules = componentModules; }).dotsteward.components.example-app.install.deb.aptSources'
assert_core_eq "[{\"name\": \"example-vendor\", \"uri\": \"https://apt.example.invalid/ubuntu\", \"suites\": [\"{codename}\"],
  \"components\": [], \"architectures\": [], \"keyUrl\": \"https://apt.example.invalid/gpg\", \"keyFingerprint\": \"$fpr\"}]" \
  "$(sources_of "$(source_with '{ }')")" "defaults"
assert_core_eq '["stable"]' "(builtins.head ($(sources_of "$(source_with '{ components = [ "stable" ]; architectures = [ "amd64" ]; }')"))).components"

assert_core_fails "$(sources_of "$(source_with '{ name = "../evil"; }')")" "apt source name"
assert_core_fails "$(sources_of "$(source_with '{ uri = "http://apt.example.invalid/ubuntu"; }')")" "HTTPS URL"
assert_core_fails "$(sources_of "$(source_with '{ keyUrl = "http://apt.example.invalid/gpg"; }')")" "HTTPS URL"
assert_core_fails "$(sources_of "$(source_with '{ keyFingerprint = "0123456789abcdef0123456789abcdef01234567"; }')")" "40 upper-case hex digits"
assert_core_fails "$(sources_of "$(source_with '{ keyFingerprint = "0123456789ABCDEF"; }')")" "40 upper-case hex digits"
assert_core_fails "$(sources_of "$(source_with '{ suites = [ ]; }')")" "suites"
