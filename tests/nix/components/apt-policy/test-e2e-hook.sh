# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness
# The E2E hook of apt-policy, run as the E2E runner runs it, over a stand-in of
# apt-config: without the drop-in it names the install step and passes, so a machine that
# has not run that sudo step stays green; with it, both keys must read false the way
# unattended-upgrades reads them, and a later file of apt.conf.d that sets one back fails
# with the step. The drop-in is the one file the component installs.

component=$DS_REPO_ROOT/modules/components/apt-policy
hook=$component/e2e-unattended.sh
[[ -x $hook ]] || ds_fail "modules/components/apt-policy/e2e-unattended.sh is missing or not executable"
assert_contains "$(<"$component/52dotsteward-unattended-upgrades")" 'Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";'
assert_contains "$(<"$component/52dotsteward-unattended-upgrades")" 'Unattended-Upgrade::Remove-New-Unused-Dependencies "false";'

apt_dir=$DS_TEST_ROOT/etc/apt
bin=$DS_TEST_ROOT/fake-bin
values=$DS_TEST_ROOT/apt-config-values
mkdir -p "$apt_dir/apt.conf.d" "$bin"
# apt-config shell VAR KEY: the value the state file gives KEY, unset when it has none.
cat >"$bin/apt-config" <<EOF_STUB
#!/usr/bin/env bash
[[ \$1 == shell ]] || exit 100
value=\$(awk -v key="\$3" '\$1 == key { print \$2 }' "$values")
[[ -z \$value ]] || printf "%s='%s'\n" "\$2" "\$value"
EOF_STUB
chmod 0755 "$bin/apt-config"

run_hook() {
  PATH=$bin:$PATH DOTSTEWARD_APT_DIR=$apt_dir DOTSTEWARD_COMPONENT=apt-policy DOTSTEWARD_PROFILE=workstation \
    DOTSTEWARD_CHECK_ONLY=1 "$hook" </dev/null
}

# Not installed yet: the step, and green.
assert_exit 0 run_hook
assert_contains "$DS_STDOUT" "apt-policy: $apt_dir/apt.conf.d/52dotsteward-unattended-upgrades is not installed yet; run: dotsteward install --profile workstation --component apt-policy"

# Installed, and apt reads it.
cp "$component/52dotsteward-unattended-upgrades" "$apt_dir/apt.conf.d/"
printf 'Unattended-Upgrade::Remove-Unused-Kernel-Packages false\nUnattended-Upgrade::Remove-New-Unused-Dependencies false\n' >"$values"
assert_exit 0 run_hook
assert_eq "" "$DS_STDOUT$DS_STDERR"

# A later file sets one key back.
printf 'Unattended-Upgrade::Remove-Unused-Kernel-Packages true\nUnattended-Upgrade::Remove-New-Unused-Dependencies false\n' >"$values"
assert_exit 1 run_hook
assert_contains "$DS_STDERR" 'apt-policy: apt reads Unattended-Upgrade::Remove-Unused-Kernel-Packages as "true", not "false"'
assert_contains "$DS_STDERR" "dotsteward install --profile workstation --component apt-policy"
assert_not_contains "$DS_STDERR" "Remove-New-Unused-Dependencies"

# Neither key set at all: both fail.
: >"$values"
assert_exit 1 run_hook
assert_contains "$DS_STDERR" 'Remove-Unused-Kernel-Packages as "", not "false"'
assert_contains "$DS_STDERR" 'Remove-New-Unused-Dependencies as "", not "false"'
