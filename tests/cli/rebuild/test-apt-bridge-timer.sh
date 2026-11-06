# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and rb_* variables come from the harness and the helpers
# The rebuild of an adopt-mode profile does not manage the deb method: a
# github-release deb component without the bridge's timer (its machine has
# not run `install --component` yet) activates like any other, with no sudo
# call for the bridge and no systemctl call.
# shellcheck source=tests/cli/rebuild/helpers.sh
source "$DS_REPO_ROOT/tests/cli/rebuild/helpers.sh"

ds_use_stubs systemctl dpkg dpkg-query dpkg-deb
set_config '
[components.example-app]
enable = true
'
manifest_edit '.components += [{
  name: "example-app", source: "instance", method: "deb", profiles: null, platforms: ["linux"], options: {},
  modes: { workstation: "adopt", fresh: "fresh" }, supported_methods: { linux: ["deb"], darwin: [] },
  install: {
    pin: null, packageNames: ["example-app"], architecture: "amd64", verifyAfterInstall: true, apt: [],
    aptSources: [],
    githubRelease: {
      repository: "example-org/example-app",
      assets: { amd64: "example-app-{version}-linux-x86_64.deb" },
      checksums: "SHA256SUMS.txt"
    }
  }
}]'

: >"$DS_CALL_LOG"
assert_exit 0 run_rebuild --profile workstation --switch
assert_eq "1" "$(ds_call_count activate)"
assert_eq "0" "$(ds_call_count systemctl)"
assert_eq "0" "$(ds_call_count sudo)"
[[ ! -e $DS_SYSTEM_ROOT/etc/systemd/system/dotsteward-apt-bridge.timer ]] ||
  ds_fail "the rebuild of an adopt-mode profile wrote the bridge's timer"
