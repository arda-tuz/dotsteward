# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# `dotsteward install` flags and refusals: --profile is
# required and must be a profile of the instance; unknown options, a missing
# manifest mirror, a manifest of another system or schema and an unknown
# lock path are refused with exit 1 before any system call.
# shellcheck source=tests/cli/methods/helpers.sh
source "$DS_REPO_ROOT/tests/cli/methods/helpers.sh"

ds_use_stubs sudo apt-get dpkg dpkg-query dpkg-deb curl

# The command is listed with its summary.
assert_exit 0 "$methods_fw/cli/dotsteward" --help
assert_contains "$DS_STDOUT" "install"
summary=$(grep -m 1 '^  install ' <<<"$DS_STDOUT")
assert_contains "$summary" "system-install phase"

assert_exit 0 run_install --help
assert_contains "$DS_STDOUT" "Usage: dotsteward install --profile PROFILE [--check-only] [--json] [--generation PATH]"

assert_exit 1 run_install
assert_eq "[dotsteward] ERROR: install: --profile is required" "$DS_STDERR"
assert_exit 1 run_install --profile
assert_eq "[dotsteward] ERROR: install: --profile requires a value" "$DS_STDERR"
assert_exit 1 run_install --profile fresh --bogus
assert_eq "[dotsteward] ERROR: install: unknown option: --bogus" "$DS_STDERR"
assert_exit 1 run_install --profile fresh --generation
assert_eq "[dotsteward] ERROR: install: --generation requires a value" "$DS_STDERR"
assert_exit 1 run_install --profile nope
assert_eq "[dotsteward] ERROR: unsupported profile: nope (profiles: workstation, fresh)" "$DS_STDERR"
assert_calls

# The manifest mirror must exist, be schema 1 and describe this system.
mv "$methods_manifest" "$DS_TEST_ROOT/manifest.json"
assert_exit 1 run_install --profile fresh
assert_eq "[dotsteward] ERROR: manifest not found: $methods_manifest (run 'dotsteward sync' to regenerate the mirrors)" "$DS_STDERR"
mv "$DS_TEST_ROOT/manifest.json" "$methods_manifest"

manifest_edit '.schema_version = 2'
assert_exit 1 run_install --profile fresh
assert_eq "[dotsteward] ERROR: unsupported manifest schema_version 2: $methods_manifest" "$DS_STDERR"
manifest_edit '.schema_version = 1 | .system = "aarch64-darwin"'
assert_exit 1 run_install --profile fresh
assert_eq "[dotsteward] ERROR: manifest $methods_manifest describes aarch64-darwin, not x86_64-linux" "$DS_STDERR"
manifest_edit '.system = "x86_64-linux"'
printf 'not json\n' >"$DS_TEST_ROOT/broken.json"
cp "$methods_manifest" "$DS_TEST_ROOT/good.json"
cp "$DS_TEST_ROOT/broken.json" "$methods_manifest"
assert_exit 1 run_install --profile fresh
assert_eq "[dotsteward] ERROR: invalid manifest: $methods_manifest" "$DS_STDERR"
cp "$DS_TEST_ROOT/good.json" "$methods_manifest"

# The running platform must be one of nix.systems.
sed -i 's/^systems = .*/systems = ["aarch64-darwin"]/' "$methods_inst/workstation.toml"
assert_exit 1 run_install --profile fresh
assert_eq "[dotsteward] ERROR: this linux machine is not in nix.systems (aarch64-darwin)" "$DS_STDERR"
sed -i 's/^systems = .*/systems = ["x86_64-linux"]/' "$methods_inst/workstation.toml"
assert_calls

# A generation's manifest is read from its home-path.
generation=$DS_TEST_ROOT/generation
assert_exit 1 run_install --profile fresh --generation "$generation"
assert_eq "[dotsteward] ERROR: manifest not found: $generation/home-path/share/dotsteward/manifest.json" "$DS_STDERR"

# A pin path the lock does not have names the component, like pinAt.
add_component example-app deb '{"pin": "desktop_packages.example-app", "packageNames": ["example-app"], "architecture": null, "verifyAfterInstall": true, "apt": []}'
assert_exit 1 run_install --profile fresh --check-only
assert_eq "[dotsteward] ERROR: versions.lock.json lacks desktop_packages.example-app (required by component example-app)" "$DS_STDERR"

# Nothing above reached the system.
assert_eq "0" "$(ds_call_count sudo)"
assert_eq "0" "$(ds_call_count curl)"
assert_eq "" "$(temp_dirs)"
