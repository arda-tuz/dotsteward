# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# One source for the platform of a named machine: its host file, which Nix reads too. When the
# file names no platform or another one than this machine runs, and the platform files make
# that a difference, gate and rebuild both stop before they build, with the step that fixes it;
# `host publish` records the platform this machine runs, and then gate builds the generation
# rebuild activates. A difference that changes nothing stops nothing.
# shellcheck source=tests/cli/host/helpers.sh
source "$DS_REPO_ROOT/tests/cli/host/helpers.sh"

remote_file() {
  git -C "$e2e_bare" show "refs/heads/main:hosts/$1.toml"
}
run_ds() {
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" "$@" </dev/null
}

add_component example external '{}'
publish_instance
cp "$(ds_fixture common/os-release/ubuntu-22.04)" "$DOTSTEWARD_OS_RELEASE"
assert_exit 0 run_host init --name laptop --profile workstation

# No platform file: an old host file without platform changes nothing, nothing stops.
write_host laptop 'system = "x86_64-linux"
profile = "workstation"'
publish_instance
assert_eq 'null' "$(effective .platform_mismatch)"
assert_eq "$(effective .nix_tags_sha256)" "$(effective .host_build.tags_sha256)"

# A platform file that leaves a component out on 22.04: the host file has no platform.
mkdir -p "$agents_inst/platforms"
printf 'schema_version = 1\n[components.example]\nunavailable = "not on jammy"\n' >"$agents_inst/platforms/ubuntu-22.04.toml"
publish_instance
assert_eq '{"file":"hosts/laptop.toml","recorded":null,"running":"ubuntu-22.04"}' "$(effective .platform_mismatch)"
assert_eq "$(effective .nix_tags_sha256)" "$(effective .host_build.tags_sha256)" "one source, one tag set"
step='hosts/laptop.toml names no platform, this machine runs ubuntu-22.04, and platforms/ makes that a difference; run: dotsteward host publish'
assert_exit 1 run_ds gate
assert_contains "$DS_STDERR" "$step"
assert_exit 1 run_ds rebuild --profile workstation --build-only
assert_contains "$DS_STDERR" "$step"

# An outdated platform: the host file says 24.04 (before a release upgrade).
write_host laptop 'system = "x86_64-linux"
profile = "workstation"
platform = "ubuntu-24.04"'
publish_instance
assert_eq '{"file":"hosts/laptop.toml","recorded":"ubuntu-24.04","running":"ubuntu-22.04"}' "$(effective .platform_mismatch)"
assert_exit 1 run_ds gate
assert_contains "$DS_STDERR" "hosts/laptop.toml names platform ubuntu-24.04, this machine runs ubuntu-22.04"

# host publish records what this machine runs; then both agree and nothing stops.
assert_exit 0 run_host publish
assert_contains "$(remote_file laptop)" 'platform = "ubuntu-22.04"'
git -C "$agents_inst" fetch -q origin && git -C "$agents_inst" merge -q --ff-only origin/main
assert_eq 'null' "$(effective .platform_mismatch)"
assert_eq "$(effective .nix_tags_sha256)" "$(effective .host_build.tags_sha256)"
assert_contains "$(effective .nix_tags)" '"no:example"'
