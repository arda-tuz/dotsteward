# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Inside the container: the drop-in of apt-policy on the real apt of this release. The E2E
# hook passes before the install (with the step), passes with the drop-in as the system
# method installs it, and fails when a later file of apt.conf.d sets a key back, the way
# unattended-upgrades would read it.
component=/framework/modules/components/apt-policy
dropin=/etc/apt/apt.conf.d/52dotsteward-unattended-upgrades
override=/etc/apt/apt.conf.d/99example-override

hook() {
  DOTSTEWARD_PROFILE=fresh "$component/e2e-unattended.sh" </dev/null
}

sudo -n rm -f "$dropin" "$override"
assert_exit 0 hook
assert_contains "$DS_STDOUT" "is not installed yet; run: dotsteward install --profile fresh --component apt-policy"

sudo -n install -D -o root -g root -m 0644 "$component/52dotsteward-unattended-upgrades" "$dropin"
assert_exit 0 hook
assert_eq "" "$DS_STDOUT$DS_STDERR"
assert_contains "$(apt-config dump)" 'Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";'

printf 'Unattended-Upgrade::Remove-New-Unused-Dependencies "true";\n' | sudo -n tee "$override" >/dev/null
assert_exit 1 hook
assert_contains "$DS_STDERR" 'Remove-New-Unused-Dependencies as "true"'
sudo -n rm -f "$dropin" "$override"
