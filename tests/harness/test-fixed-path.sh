# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# A test keeps the tools it started with when a profile on PATH switches while it runs. A user
# profile (such as ~/.nix-profile/bin) is a symbolic link that an activation on the machine
# repoints at another generation at any moment; a test that ran with the link on PATH lost a
# tool half way (`jq: No such file or directory`). The harness puts every PATH entry on PATH
# as the directory it resolves to when the test starts, so a switch during the run changes
# nothing for the test.

profiles=$DS_TEST_ROOT/profiles
mkdir -p "$profiles/generation-1/bin" "$profiles/generation-2/bin" "$DS_TEST_ROOT/inner"
printf '#!/bin/sh\necho generation-1\n' >"$profiles/generation-1/bin/example-tool"
chmod 0755 "$profiles/generation-1/bin/example-tool"
ln -s generation-1 "$profiles/profile"

# The inner test calls the tool, switches the profile to a generation without it, as an
# activation of the machine does, and calls the tool again.
cat >"$DS_TEST_ROOT/inner/test-profile-switch.sh" <<'EOF'
# shellcheck shell=bash
assert_eq generation-1 "$(example-tool)"
ln -sfn generation-2 "$DS_FIXED_PATH_PROFILES/profile"
assert_eq generation-1 "$(example-tool)"
case ":$PATH:" in
  *":$DS_FIXED_PATH_PROFILES/profile/bin:"*) ds_fail "the profile link is still on PATH: $PATH" ;;
esac
EOF

assert_exit 0 env PATH="$profiles/profile/bin:$PATH" DS_FIXED_PATH_PROFILES="$profiles" \
  bash "$DS_REPO_ROOT/tests/run.sh" --jobs 1 "$DS_TEST_ROOT/inner"
assert_contains "$DS_STDOUT" "PASS"
assert_not_contains "$DS_STDOUT" "FAIL"
assert_eq generation-2 "$(basename "$(readlink "$profiles/profile")")"
