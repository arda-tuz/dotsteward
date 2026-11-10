# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Inside the container: the writer of the system method (methods_system_install, the one of
# `dotsteward install`) against the real root of this release, with the file of apt-policy.
# It lands root-owned with its mode by a rename (a new inode, no temporary file left), apt
# reads it, a second run writes nothing, and the check finds wrong bytes and a wrong owner.
unset DOTSTEWARD_SYSTEM_ROOT DOTSTEWARD_APT_DIR
component=/framework/modules/components/apt-policy
dropin=/etc/apt/apt.conf.d/52dotsteward-unattended-upgrades
printf 'container-test\n' | sudo -S -p '' -v
sudo -n rm -f "$dropin"

# methods SCRIPT: SCRIPT in a bash with the methods library and a manifest of apt-policy.
methods() {
  DS_MANIFEST_JSON=$(jq -n --arg path "$dropin" --rawfile text "$component/52dotsteward-unattended-upgrades" \
    '{components: [{name: "apt-policy", method: "system", install: {files: [{path: $path, text: $text, mode: "0644"}]}}]}') \
    DS_RUNTIME_PLATFORM=linux DOTSTEWARD_LIB=/framework/cli/lib bash --noprofile --norc -c '
      set -Eeuo pipefail
      source /framework/cli/lib/lib.sh
      source /framework/cli/lib/methods.sh
      code=0
      '"$1"' || code=$?
      printf "%s: %s\n" "$METHODS_STATUS" "$METHODS_DETAIL"
      exit "$code"'
}

assert_exit 1 methods '_methods_system_check apt-policy'
assert_contains "$DS_STDOUT" "failed: system file $dropin is missing"
assert_exit 0 methods 'methods_system_install apt-policy'
assert_contains "$DS_STDOUT" "installed: 1 system file written"
assert_eq "0:0 644" "$(stat -c '%u:%g %a' "$dropin")"
cmp -s "$component/52dotsteward-unattended-upgrades" "$dropin" || ds_fail "the bytes differ"
assert_contains "$(apt-config dump)" 'Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";'
assert_exit 0 methods '_methods_system_check apt-policy'
assert_contains "$DS_STDOUT" "satisfied: 1 system file as the component has them"
assert_exit 0 methods 'methods_system_install apt-policy'
assert_contains "$DS_STDOUT" "satisfied:"

# Wrong bytes: replaced by a rename, nothing temporary left.
printf 'Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";\n' | sudo -n tee "$dropin" >/dev/null
before=$(stat -c %i "$dropin")
assert_exit 1 methods '_methods_system_check apt-policy'
assert_contains "$DS_STDOUT" "differs from the component"
assert_exit 0 methods 'methods_system_install apt-policy'
[[ $(stat -c %i "$dropin") != "$before" ]] || ds_fail "the file was written in place, not renamed over"
[[ -z $(find /etc/apt/apt.conf.d -name '.dotsteward-*') ]] || ds_fail "a temporary file stayed"
cmp -s "$component/52dotsteward-unattended-upgrades" "$dropin" || ds_fail "the bytes differ after the repair"

# A wrong owner is a difference too.
sudo -n chown "$(id -u):$(id -g)" "$dropin"
assert_exit 1 methods '_methods_system_check apt-policy'
assert_contains "$DS_STDOUT" "is owned by $(id -u):$(id -g), not 0:0"
assert_exit 0 methods 'methods_system_install apt-policy'
assert_eq "0:0 644" "$(stat -c '%u:%g %a' "$dropin")"
sudo -n rm -f "$dropin"
