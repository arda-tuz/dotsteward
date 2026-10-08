# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # literal $ in test values and bash -c scripts
# current_platform, require_safe_identity (Linux and macOS user name
# rules, a safe absolute existing home) and require_profile (the
# profile names of the loaded configuration).
# shellcheck source=tests/cli/lib/helpers.sh
source "$DS_REPO_ROOT/tests/cli/lib/helpers.sh"

# current_platform: DOTSTEWARD_PLATFORM, else the kernel name.
assert_eq linux "$(DOTSTEWARD_PLATFORM=linux current_platform)"
assert_eq darwin "$(DOTSTEWARD_PLATFORM=darwin current_platform)"
case $(uname -s) in
  Linux) assert_eq linux "$(current_platform)" ;;
  Darwin) assert_eq darwin "$(current_platform)" ;;
esac
platform_windows() { DOTSTEWARD_PLATFORM=windows current_platform; }
assert_exit 1 platform_windows
assert_eq "[dotsteward] ERROR: DOTSTEWARD_PLATFORM: expected linux or darwin, got windows" "$DS_STDERR"

# identity CHECK USER HOME: runs require_safe_identity on PLATFORM.
identity() {
  local platform=$1
  USER=$2 HOME=$3 DOTSTEWARD_PLATFORM=$platform require_safe_identity
}
home=$DS_TEST_ROOT/home
mkdir -p "$DS_TEST_ROOT/odd/with space" "$DS_TEST_ROOT/odd/quote\"d" "$DS_TEST_ROOT/odd/single'q" \
  "$DS_TEST_ROOT/odd/dollar\$x" "$DS_TEST_ROOT/odd/back\\slash" "$DS_TEST_ROOT/odd/tab"$'\t'"x" \
  "$DS_TEST_ROOT/odd/new"$'\n'"line"

for user in alice _svc a1 a-b a_b; do
  assert_exit 0 identity linux "$user" "$home"
done
for user in Alice a.b 1abc -a '' 'a b' 'a"b' "a'b" 'a$b' $'a\nb' $'\xc3\xa9'; do
  assert_exit 1 identity linux "$user" "$home"
  assert_eq '[dotsteward] ERROR: unsafe user name: Linux user names must match ^[a-z_][a-z0-9_-]*$' "$DS_STDERR" \
    "linux user [$user]"
done
for user in Alice Alice.B _x a-b a1.2 alice; do
  assert_exit 0 identity darwin "$user" "$home"
done
for user in 1abc .a -a '' 'a b' 'a"b' 'a$b' $'a\nb' 'a/b'; do
  assert_exit 1 identity darwin "$user" "$home"
  assert_eq '[dotsteward] ERROR: unsafe user name: macOS user names must match ^[A-Za-z_][A-Za-z0-9_.-]*$' \
    "$DS_STDERR" "darwin user [$user]"
done

home_message='[dotsteward] ERROR: unsafe HOME: it must be an absolute path of an existing directory without whitespace, quotes, $ or backslash'
for bad in relative/home "" "$DS_TEST_ROOT/missing" "$DS_TEST_ROOT/odd/with space" "$DS_TEST_ROOT/odd/quote\"d" \
  "$DS_TEST_ROOT/odd/single'q" "$DS_TEST_ROOT/odd/dollar\$x" "$DS_TEST_ROOT/odd/back\\slash" \
  "$DS_TEST_ROOT/odd/tab"$'\t'"x" "$DS_TEST_ROOT/odd/new"$'\n'"line"; do
  for platform in linux darwin; do
    assert_exit 1 identity "$platform" alice "$bad"
    assert_eq "$home_message" "$DS_STDERR" "HOME [$bad] on $platform"
  done
done
touch "$DS_TEST_ROOT/a-file"
assert_exit 1 identity linux alice "$DS_TEST_ROOT/a-file"
ln -s "$home" "$DS_TEST_ROOT/home-link"
assert_exit 0 identity linux alice "$DS_TEST_ROOT/home-link"
# Unset variables are unsafe, not an unbound-variable crash.
no_user() { unset USER; DOTSTEWARD_PLATFORM=linux require_safe_identity; }
assert_exit 1 no_user
assert_contains "$DS_STDERR" "unsafe user name"
no_home() { unset HOME; DOTSTEWARD_PLATFORM=linux require_safe_identity; }
assert_exit 1 no_home
assert_eq "$home_message" "$DS_STDERR"

# require_profile accepts exactly the profile names of the configuration.
assert_exit 1 require_profile main
assert_eq "[dotsteward] ERROR: require_profile: the instance configuration is not loaded" "$DS_STDERR"
# shellcheck disable=SC2034 # read by require_profile
DS_PROFILES_NAMES=(main fresh.v2)
assert_exit 0 require_profile main
assert_exit 0 require_profile fresh.v2
for bad in other '' fresh main.; do
  assert_exit 1 require_profile "$bad"
  assert_eq "[dotsteward] ERROR: unsupported profile: $bad (profiles: main, fresh.v2)" "$DS_STDERR"
done
