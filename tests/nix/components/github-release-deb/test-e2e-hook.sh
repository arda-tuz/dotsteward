# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness
# The shared E2E hook modules/core/github-release-deb-e2e.sh, run as the
# E2E runner runs it (the hook environment with DOTSTEWARD_COMPONENT), over
# stand-ins of dpkg-query, dpkg, apt-cache and the component's CLI: it
# passes for a package at or above its floor that ships its desktop entry,
# whose CLI answers and that APT takes from the local APT bridge, and fails
# with one message for each of these conditions that does not hold. It reports
# a bridge timer that is not enabled and an APT hook of an older framework that
# is still in place, with the step that fixes them, and stays green for both.

hook=$DS_REPO_ROOT/modules/core/github-release-deb-e2e.sh
[[ -x $hook ]] || ds_fail "modules/core/github-release-deb-e2e.sh is missing or not executable"

name=example-app
instance=$DS_TEST_ROOT/instance
bin=$DS_TEST_ROOT/fake-bin
state=$DS_TEST_ROOT/fake-state
mkdir -p "$instance" "$bin" "$state"
jq -n --arg n "$name" '{desktop_packages: {($n): {minimum_version: "1.2.0",
  url: "https://example.com/example-app-1.2.0.deb", size: 1, sha256: ("0" * 64)}}}' >"$instance/versions.lock.json"

# State of the stand-ins: the installed version (empty: not installed), the
# package's file list, the CLI's exit status and the APT policy text.
printf '1.3.0-1\n' >"$state/version"
printf '/usr/bin/%s\n/usr/bin/%s-cli\n/usr/share/applications/com.example.app.desktop\n' "$name" "$name" >"$state/files"
printf '0\n' >"$state/cli"
printf '%s:\n  Installed: 1.3.0-1\n  Version table:\n *** 1.3.0-1 500\n        500 file:/var/lib/dotsteward/apt-bridge ./ Packages\n' "$name" >"$state/policy"
mkdir -p "$DS_SYSTEM_ROOT/usr/share/applications"
: >"$DS_SYSTEM_ROOT/usr/share/applications/com.example.app.desktop"

# Stand-ins start with the running bash: the Nix sandbox has no /usr/bin/env.
cat >"$bin/dpkg-query" <<STUB
#!$BASH
case "\$1" in
  -W) version=\$(<"$state/version"); [[ -n \$version ]] || exit 1; printf '%s' "\$version" ;;
  -L) [[ -n \$(<"$state/version") ]] || exit 1; cat "$state/files" ;;
  *) exit 64 ;;
esac
STUB
printf '#!%s\n' "$BASH" >"$bin/dpkg"
cat >>"$bin/dpkg" <<'STUB'
[[ $1 == --compare-versions && $3 == ge ]] || exit 64
[[ $(printf '%s\n%s\n' "$4" "${2%-*}" | sort -V | head -n 1) == "$4" ]]
STUB
# apt-cache writes with the bash builtin, which takes SIGPIPE like apt-cache
# does; some cat builds swallow a broken pipe.
cat >"$bin/apt-cache" <<STUB
#!$BASH
[[ \$1 == policy ]] || exit 64
printf '%s\n' "\$(<"$state/policy")"
STUB
cat >"$bin/$name-cli" <<STUB
#!$BASH
[[ \$1 == --version ]] || exit 64
echo "$name 1.3.0"
exit "\$(<"$state/cli")"
STUB
printf '#!%s\nexit 0\n' "$BASH" >"$bin/systemctl"
chmod +x "$bin"/*

units=$DS_SYSTEM_ROOT/etc/systemd/system
timer=$units/dotsteward-apt-bridge.timer
timer_link=$units/timers.target.wants/dotsteward-apt-bridge.timer
old_hook=$DOTSTEWARD_APT_DIR/apt.conf.d/60dotsteward-apt-bridge
mkdir -p "$units/timers.target.wants" "$DOTSTEWARD_APT_DIR/apt.conf.d"
: >"$timer"
ln -s "$timer" "$timer_link"

run_hook() {
  env PATH="$bin:$PATH" DOTSTEWARD_LIB="$DS_REPO_ROOT/cli/lib" DOTSTEWARD_INSTANCE="$instance" \
    DOTSTEWARD_COMPONENT="$name" DOTSTEWARD_PROFILE=workstation DOTSTEWARD_CHECK_ONLY=1 "$hook"
}

assert_exit 0 run_hook
assert_contains "$DS_STDOUT$DS_STDERR" "$name 1.3.0-1: floor 1.2.0, desktop entry, CLI and the local APT bridge"
assert_not_contains "$DS_STDOUT$DS_STDERR" "bridge timer"
assert_not_contains "$DS_STDOUT$DS_STDERR" "bridge hook"

# The timer that is missing, or not enabled, is one line and no failure.
step="run dotsteward install --profile workstation --component $name"
rm -f -- "$timer_link"
assert_exit 0 run_hook
assert_contains "$DS_STDERR" "$name: bridge timer not installed: $step"
assert_contains "$DS_STDOUT" "$name 1.3.0-1: floor 1.2.0, desktop entry, CLI and the local APT bridge"
rm -f -- "$timer"
assert_exit 0 run_hook
assert_contains "$DS_STDERR" "$name: bridge timer not installed: $step"
: >"$timer"
ln -s "$timer" "$timer_link"

# So is the APT hook of an older framework next to an enabled timer.
: >"$old_hook"
assert_exit 0 run_hook
assert_contains "$DS_STDERR" "$name: obsolete bridge hook $old_hook: $step"
rm -f -- "$old_hook"

# A machine without systemd can take in no timer: nothing to report.
rm -f -- "$timer_link" "$timer"
no_systemctl=$(PATH=$bin:$PATH ds_path_without systemctl)
run_without_systemd() {
  env PATH="$no_systemctl" DOTSTEWARD_LIB="$DS_REPO_ROOT/cli/lib" DOTSTEWARD_INSTANCE="$instance" \
    DOTSTEWARD_COMPONENT="$name" DOTSTEWARD_CHECK_ONLY=1 "$hook"
}
assert_exit 0 run_without_systemd
assert_not_contains "$DS_STDOUT$DS_STDERR" "bridge timer"
: >"$timer"
ln -s "$timer" "$timer_link"

printf '1.1.9-1\n' >"$state/version"
assert_exit 1 run_hook
assert_contains "$DS_STDERR" "$name: the installed package 1.1.9-1 is below the floor 1.2.0"

printf '\n' >"$state/version"
assert_exit 1 run_hook
assert_contains "$DS_STDERR" "$name: the package is not installed"

printf '1.3.0-1\n' >"$state/version"
rm -f -- "$DS_SYSTEM_ROOT/usr/share/applications/com.example.app.desktop"
assert_exit 1 run_hook
assert_contains "$DS_STDERR" "$name: the desktop entry /usr/share/applications/com.example.app.desktop is missing"

printf '/usr/bin/%s\n' "$name" >"$state/files"
assert_exit 1 run_hook
assert_contains "$DS_STDERR" "$name: the package ships no desktop entry"

printf '/usr/share/applications/com.example.app.desktop\n' >"$state/files"
: >"$DS_SYSTEM_ROOT/usr/share/applications/com.example.app.desktop"
printf '3\n' >"$state/cli"
assert_exit 1 run_hook
assert_contains "$DS_STDERR" "$name: $name-cli --version does not answer"

printf '0\n' >"$state/cli"
# A newer version waiting in the bridge puts the bridge line before more
# output. The filler is larger than a pipe buffer, so a reader that stops at
# the first match leaves apt-cache to die of SIGPIPE every time.
{
  printf '%s:\n  Installed: 1.3.0-1\n  Candidate: 1.4.0-1\n  Version table:\n     1.4.0-1 500\n' "$name"
  printf '        500 file:/var/lib/dotsteward/apt-bridge ./ Packages\n'
  printf ' *** 1.3.0-1 100\n        100 /var/lib/dpkg/status\n'
  for ((i = 0; i < 4096; i++)); do printf '        %0120d\n' "$i"; done
} >"$state/policy"
assert_exit 0 run_hook
assert_contains "$DS_STDOUT$DS_STDERR" "$name 1.3.0-1: floor 1.2.0, desktop entry, CLI and the local APT bridge"

printf '%s:\n  Installed: 1.3.0-1\n        500 https://example.com/apt ./ Packages\n' "$name" >"$state/policy"
assert_exit 1 run_hook
assert_contains "$DS_STDERR" "$name: APT does not take the package from the local APT bridge"

assert_exit 1 env -u DOTSTEWARD_COMPONENT DOTSTEWARD_LIB="$DS_REPO_ROOT/cli/lib" "$hook"
assert_contains "$DS_STDERR" "DOTSTEWARD_COMPONENT is not set"
