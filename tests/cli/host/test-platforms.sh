# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs and hook scripts are single-quoted on purpose
# The platform layer: platforms/<id>.toml says what differs on one operating system and
# version. `dotsteward host platform` names the platform of this machine, its layers from
# the most specific one and what they say; a component the layer calls unavailable is left
# out by every command, with the reason platform, and Nix gets a no: tag for it. `host
# check` holds the files to their schema.
# shellcheck source=tests/cli/host/helpers.sh
source "$DS_REPO_ROOT/tests/cli/host/helpers.sh"

ran=$DS_TEST_ROOT/ran.log
: >"$ran"
add_component example external '{}'
add_e2e_hook example end-check late <<EOF_HOOK
printf 'e2e hook\n' >>"$ran"
EOF_HOOK
publish_instance

write_platform() {
  mkdir -p "$agents_inst/platforms"
  printf 'schema_version = 1\n%s\n' "${2:-}" >"$agents_inst/platforms/$1.toml"
}

platform_json() {
  assert_exit 0 run_host platform --json
  jq -c "$1" <<<"$DS_STDOUT"
}

problems() {
  assert_exit 1 run_host check
  printf '%s\n' "$DS_STDERR"
  assert_exit 1 "$agents_fw/cli/dotsteward" --instance "$agents_inst" static --only hosts </dev/null
  printf '%s\n' "$DS_STDERR"
}

# --- No platform file: the platform is named, nothing differs ------------------------
cp "$(ds_fixture common/os-release/ubuntu-22.04)" "$DOTSTEWARD_OS_RELEASE"
assert_eq '"ubuntu-22.04"' "$(platform_json .id)"
assert_eq '["ubuntu-22.04","ubuntu","linux"]' "$(platform_json .layers)"
assert_eq '[]' "$(platform_json .files)"
assert_eq '{}' "$(platform_json .components)"
assert_exit 0 run_host platform
assert_contains "$DS_STDOUT" "platform: ubuntu-22.04 (layers: ubuntu-22.04, ubuntu, linux)"
assert_contains "$DS_STDOUT" "files: (none)"
assert_eq '[]' "$(effective .skip.components)"

# --- The release file: a component it calls unavailable is gone here ------------------
write_platform ubuntu-22.04 '
[fast_path]
os_id = "ubuntu"
os_version = "22.04"
architecture = "x86_64"

[components.example]
unavailable = "the vendor publishes nothing for jammy"'
assert_exit 0 run_host check
assert_contains "$DS_STDOUT" "platforms: 1 file, no problem"
assert_eq '["platforms/ubuntu-22.04.toml"]' "$(platform_json .files)"
assert_eq '{"example":{"unavailable":"the vendor publishes nothing for jammy","layer":"ubuntu-22.04"}}' \
  "$(platform_json .components)"
assert_eq '{"os_id":"ubuntu","os_version":"22.04","architecture":"x86_64"}' "$(platform_json .fast_path)"
assert_exit 0 run_host platform
assert_contains "$DS_STDOUT" "example: unavailable (ubuntu-22.04: the vendor publishes nothing for jammy)"
assert_eq '["example"]' "$(effective .skip.components)"
assert_eq '{"component:example":"platform"}' "$(effective .reasons)"
# Nix leaves it out too, on a machine with a name and on one without.
assert_contains "$(effective .nix_tags)" '"no:example"'
# What needs it is left out with it, also on a machine without a name.
add_component needer external '{}'
manifest_edit '(.components[] | select(.name == "needer")).requires = ["example"]'
publish_instance
assert_eq '["example","needer"]' "$(effective .skip.components)"
assert_eq '"requires"' "$(effective '.reasons["component:needer"]')"
assert_contains "$(effective .nix_tags)" '"no:needer"'
# (requires is the CLI's alone: Nix never fails for it, so it goes before the tags of gate.)
manifest_edit '(.components[] | select(.name == "needer")) |= del(.requires)'
publish_instance
write_host laptop 'platform = "ubuntu-22.04"'
publish_instance
name_machine laptop
assert_eq '["machine:laptop","no:example"]' "$(effective .nix_tags)"
# The host file names the release: gate builds the generation rebuild activates.
write_host laptop 'platform = "ubuntu-22.04"'
publish_instance
assert_eq "$(effective .nix_tags_sha256)" "$(effective '.host_build.tags_sha256')" "the tags of the build of gate"
: >"$ran"
assert_exit 0 run_e2e --list
assert_not_contains "$DS_STDOUT" "example:end-check"
assert_exit 0 run_e2e
assert_eq "" "$(<"$ran")" "the hook of an unavailable component does not run"
assert_exit 0 run_skills effective
assert_contains "$DS_STDOUT" "components left out: example (platform)"

# --- Another release of the same system: the component is back -----------------------
cp "$(ds_fixture common/os-release/ubuntu-24.04)" "$DOTSTEWARD_OS_RELEASE"
assert_eq '"ubuntu-24.04"' "$(platform_json .id)"
assert_eq '[]' "$(platform_json .files)"
# The host file still names 22.04, the one source: gate and rebuild stop until it says 24.04.
assert_eq '"ubuntu-22.04"' "$(effective .platform_mismatch.recorded)"
write_host laptop 'platform = "ubuntu-24.04"'
publish_instance
assert_eq 'null' "$(effective .platform_mismatch)"
assert_eq '[]' "$(effective .skip.components)"
assert_exit 0 run_e2e
assert_contains "$(<"$ran")" "e2e hook"

# --- Layers: the more specific one gives the reason, a general one reaches every release ---
write_platform linux '
[components.example]
unavailable = "not on linux"'
assert_eq '["platforms/linux.toml"]' "$(platform_json .files)"
assert_eq '{"example":{"unavailable":"not on linux","layer":"linux"}}' "$(platform_json .components)"
write_platform ubuntu-24.04 '
[components.example]
unavailable = "not on noble"'
assert_eq '["platforms/ubuntu-24.04.toml","platforms/linux.toml"]' "$(platform_json .files)"
assert_eq '{"example":{"unavailable":"not on noble","layer":"ubuntu-24.04"}}' "$(platform_json .components)"
rm "$agents_inst/platforms/linux.toml" "$agents_inst/platforms/ubuntu-24.04.toml"

# --- macOS: the major version names the release -------------------------------------
assert_eq '"macos-15"' "$(DOTSTEWARD_PLATFORM=darwin platform_json .id)"
assert_eq '["macos-15","macos","darwin"]' "$(DOTSTEWARD_PLATFORM=darwin platform_json .layers)"

# --- host check holds the files to the schema ----------------------------------------
write_platform ubuntu-26.04 'unknown = 1'
assert_contains "$(problems)" "platforms/ubuntu-26.04.toml: unknown key unknown"
write_platform ubuntu-26.04 '[components.example]
unavailable = ""'
assert_contains "$(problems)" "platforms/ubuntu-26.04.toml: components.example.unavailable: expected a non-empty string"
write_platform ubuntu-26.04 '[fast_path]
os_id = "ubuntu"'
assert_contains "$(problems)" "platforms/ubuntu-26.04.toml: missing required key fast_path.os_version"
write_platform macos-15 '[fast_path]
os_id = "ubuntu"
os_version = "26.04"
architecture = "x86_64"'
assert_contains "$(problems)" "platforms/macos-15.toml: a fast path is for a Linux release"
rm "$agents_inst/platforms/macos-15.toml"
write_platform ubuntu-26.04 '[fast_path]
os_id = "ubuntu"
os_version = "24.04"
architecture = "x86_64"'
assert_contains "$(problems)" "platforms/ubuntu-26.04.toml: the fast path names ubuntu-24.04"
rm "$agents_inst/platforms/ubuntu-26.04.toml"
printf 'schema_version = 1\n' >"$agents_inst/platforms/Not_A_Platform.toml"
assert_contains "$(problems)" "platforms/Not_A_Platform.toml: expected platforms/<platform>.toml"
rm "$agents_inst/platforms/Not_A_Platform.toml"
printf 'schema_version = [\n' >"$agents_inst/platforms/ubuntu-24.04.toml"
assert_contains "$(problems)" "platforms/ubuntu-24.04.toml: invalid TOML"
assert_exit 1 run_host platform --json
assert_contains "$DS_STDERR" "platforms/ubuntu-24.04.toml: invalid TOML"
rm "$agents_inst/platforms/ubuntu-24.04.toml"
assert_exit 0 run_host check
