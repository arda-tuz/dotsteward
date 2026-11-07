# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Inside the container: the plans of the real history, applied by the real dpkg. dpkg ends
# where the plan said, the pin file tells what dpkg has now, and a second run has nothing
# left to do.
# shellcheck source=tests/container/scenarios/lib.sh
source "$DS_REPO_ROOT/tests/container/scenarios/lib.sh"
# shellcheck source=tests/apt-worlds/helpers.sh
source "$DS_REPO_ROOT/tests/apt-worlds/helpers.sh"

apt --version | head -n 1
sudo_open
world_modinfo
MODULE=linux-modules-nvidia-595-open

# commit_world NAME [REQUEST]: the world, its pin, one commit that goes through; then the
# state that holds after every commit.
commit_world() {
  world_install "$1"
  engine_ok policy
  engine_ok commit "${2:-{\"mode\": \"all\"\}}"
  assert_json "$ENGINE" '.status == "committed" and .committed == true'
  settled
}

settled() {
  audit_clean
  pin_matches_dpkg
  candidates_stay
  assert_not_contains "$(apt-get -s full-upgrade 2>/dev/null)" "Remv "
}

# Kernel and module at the same string.
commit_world same-string
assert_eq "$K44" "$(version_of linux-generic-hwe-24.04)"
assert_eq "$K44" "$(version_of "$MODULE-generic-hwe-24.04")"
assert_eq "$K44" "$(version_of "$MODULE-7.0.0-44-generic")"
assert_eq "$K44" "$(version_of linux-image-7.0.0-44-generic)"
assert_eq "$K42" "$(version_of linux-image-7.0.0-42-generic)" "the kernel before stays"
assert_eq "$K38+1" "$(version_of "$MODULE-7.0.0-38-generic")" "the fallback keeps its module"
assert_json "$ENGINE" '.after.kernel.abi == "7.0.0-44" and .after.kernel.version == "7.0.0-44.44~24.04.1"'
# The second run converges: nothing to do, the same pin.
engine_ok commit '{"mode": "all"}'
assert_json "$ENGINE" '.status == "nothing" and .committed == false'
settled

# The module meta package at +N.
commit_world plus-n
assert_eq "$K44" "$(version_of linux-generic-hwe-24.04)"
assert_eq "$K44+1" "$(version_of "$MODULE-generic-hwe-24.04")"
assert_eq "$K44+1" "$(version_of "$MODULE-7.0.0-44-generic")"

# A driver move: the versioned firmware arrives, the i386 libraries move too, the fallback kernel
# loses its module and the report says it; the old packages are kept for the way back.
commit_world driver-respin
assert_eq "$D106" "$(version_of nvidia-driver-595-open)"
assert_eq "$K42+1" "$(version_of "$MODULE-generic-hwe-24.04")"
assert_eq "$K42+1" "$(version_of "$MODULE-7.0.0-42-generic")"
assert_eq "$D106" "$(version_of nvidia-firmware-595-595.106.01)"
assert_eq "$D106" "$(version_of libnvidia-gl-595:i386)"
assert_eq "$D106" "$(version_of libnvidia-gl-595:amd64)"
assert_eq "" "$(version_of "$MODULE-7.0.0-38-generic")"
assert_json "$ENGINE" '.items[] | select(.code == "module-loss") | .packages == ["linux-modules-nvidia-595-open-7.0.0-38-generic"]'
assert_json "$DOTSTEWARD_STATE_ROOT/review.json" '[.items[].code] | index("module-loss") != null'
assert_json "$DOTSTEWARD_STATE_ROOT/review.json" '.exit_code == 0'
assert_json "$ENGINE" '.rollback.kept | map(select(startswith("nvidia-driver-595-open_595.99.02"))) | length == 1'
assert_json "$ENGINE" '.rollback.kept | map(select(startswith("linux-modules-nvidia-595-open-7.0.0-38-generic_"))) | length == 1'
assert_json "$ENGINE" '.rollback.missing == []'
[[ -f /var/cache/dotsteward/apt-rollback/nvidia-driver-595-open_595.99.02-0ubuntu0.24.04.1_amd64.deb ]] ||
  ds_fail "the old driver is not in the rollback cache"

# With a respin for the fallback too, nothing goes.
commit_world driver-respin-both
assert_eq "$K38+2" "$(version_of "$MODULE-7.0.0-38-generic")"
assert_eq "$D106" "$(version_of nvidia-driver-595-open)"

# A packaging bump inside the range moves the driver alone.
commit_world packaging-bump
assert_eq "$D99B" "$(version_of nvidia-driver-595-open)"
assert_eq "$K42" "$(version_of linux-generic-hwe-24.04)"

# A new kernel whose module needs the new driver: both, in one transaction.
commit_world kernel-and-driver
assert_eq "$K44" "$(version_of linux-generic-hwe-24.04)"
assert_eq "$D106" "$(version_of nvidia-driver-595-open)"
assert_eq "" "$(version_of "$MODULE-7.0.0-42-generic")"
assert_eq "" "$(version_of "$MODULE-7.0.0-38-generic")"
assert_json "$ENGINE" '.items[] | select(.code == "module-loss") | .packages | length == 2'

# Worlds in which nothing moves: a commit changes nothing and repairs the pin.
for name in no-module driver-ahead transitional phase-module phase-kernel new-series proposed-and-ppa; do
  world_install "$name"
  before=$(gated_state)
  engine_ok commit '{"mode": "all"}'
  assert_json "$ENGINE" '.status == "nothing" and .committed == false' "world $name"
  assert_eq "$before" "$(gated_state)" "world $name"
  pin_matches_dpkg
  candidates_stay
done

# The owner's word moves a new series; the same transaction takes the module along.
commit_world new-series '{"mode": "all", "accept": ["series:kernel=7.4"]}'
assert_eq "$K74" "$(version_of linux-generic-hwe-24.04)"
assert_eq "$K74" "$(version_of "$MODULE-7.4.0-5-generic")"

commit_world new-series-nvidia '{"mode": "tracked", "accept": ["series:nvidia=615-open"]}'
assert_eq "$D615" "$(version_of nvidia-driver-615-open)"
assert_eq "$K42" "$(version_of linux-modules-nvidia-615-open-7.0.0-42-generic)"
assert_eq "" "$(version_of nvidia-driver-595-open)"
assert_eq "" "$(version_of nvidia-dkms-615-open)"

# A refused plan changes nothing; the run waits for a person.
world_install dkms-pull
before=$(gated_state)
engine commit '{"mode": "all"}'
assert_eq 3 "$ENGINE_STATUS"
assert_json "$ENGINE" '.status == "refused" and .committed == false'
assert_json "$DOTSTEWARD_STATE_ROOT/review.json" '.items[] | select(.code == "apt-denied") | .class == "dkms"'
assert_eq "$before" "$(gated_state)"
pin_matches_dpkg

# A package cannot be fetched: a partial run, nothing moved, the next run can do it all.
world_install same-string
engine_ok policy
before=$(gated_state)
sudo -n find /srv/world/repo/pool -name 'linux-image-7.0.0-44-generic_*' -delete
engine commit '{"mode": "all"}'
assert_eq 6 "$ENGINE_STATUS"
assert_json "$ENGINE" '.status == "fetch-failed" and .committed == false'
assert_eq "$before" "$(gated_state)"
audit_clean
pin_matches_dpkg

# Tracked: the tracked package moves, a phased one does not, an untracked one does not.
world_install tracked
engine_ok commit '{"mode": "tracked", "tracked": ["example-tracked", "example-lib"]}'
assert_eq "2.0-1" "$(version_of example-tracked)"
assert_eq "1.0-1" "$(version_of example-lib)"
assert_eq "1.0-1" "$(version_of example-other)"
assert_eq "6.8.0-147.147" "$(version_of linux-libc-dev)"

# Under every other mode the phased package also stays.
world_install tracked
engine_ok commit '{"mode": "all"}'
assert_eq "2.0-1" "$(version_of example-other)"
assert_eq "1.0-1" "$(version_of example-lib)"

# A soname transition and split firmware go through a real dpkg.
world_install firmware-split
engine_ok commit '{"mode": "all"}'
assert_eq "20240318.git3b128b60-0ubuntu3.1" "$(version_of linux-firmware-misc)"
world_install soname
engine_ok commit '{"mode": "all"}'
assert_eq "3.15.0-1" "$(version_of libgeos3.15.0)"
assert_eq "3.14.1-1" "$(version_of libgeos3.14.1)" "the old soname stays until a person removes it"

# A configuration file changed here stays as it is, without a question; the new one lands
# next to it and the report names it.
world_install conffile
sudo -n sh -c 'printf "changed here\n" >/etc/example-conf.conf'
engine_ok commit '{"mode": "all"}'
assert_eq "2.0-1" "$(version_of example-conf)"
assert_eq "changed here" "$(</etc/example-conf.conf)"
assert_eq "packaged 2" "$(</etc/example-conf.conf.dpkg-dist)"
assert_json "$ENGINE" '.dpkg_dist == ["/etc/example-conf.conf.dpkg-dist"]'
assert_json "$DOTSTEWARD_STATE_ROOT/review.json" '.items[] | select(.code == "dpkg-dist") | .path == "/etc/example-conf.conf.dpkg-dist"'

# The way back by hand, from the rollback cache: the pin follows dpkg, nothing moves it up again.
world_modinfo
world_install bump-security
engine_ok policy
engine_ok commit '{"mode": "all"}'
assert_eq "$D99B" "$(version_of nvidia-driver-595-open)"
pin_matches_dpkg
apt_root sh -c 'dpkg -i --force-downgrade /var/cache/dotsteward/apt-rollback/*.deb' >"$out_dir/rollback.log" 2>&1 ||
  ds_fail "the way back failed: $(tail -n 5 "$out_dir/rollback.log")"
assert_eq "$D99" "$(version_of nvidia-driver-595-open)"
pin_matches_dpkg
candidates_stay
assert_not_contains "$(apt-get -s upgrade 2>/dev/null)" "Inst nvidia-"
apt_root unattended-upgrade >/dev/null 2>&1
assert_eq "$D99" "$(version_of nvidia-driver-595-open)" "unattended-upgrade after the way back"
# The hook wrote what the engine writes.
engine_ok policy
assert_json "$ENGINE" '.pin.changed == false and .hook.changed == false'
# A hook that cannot work costs dpkg nothing.
sudo -n sh -c "printf 'not python\n' >$PIN_SYNC_DIR/pin-sync.py"
apt_root apt-get -y -q install --reinstall nvidia-prime >"$out_dir/reinstall.log" 2>&1 ||
  ds_fail "dpkg failed through a broken hook: $(tail -n 5 "$out_dir/reinstall.log")"
engine_ok policy
assert_json "$ENGINE" '.hook.changed == true'
# Without the classes the hook goes too.
engine_ok policy '{"gated": false}'
assert_json "$ENGINE" '.pin.present == false and .hook.present == false'
[[ ! -e $PIN_HOOK && ! -e $PIN_SYNC_DIR/pin-sync.py ]] || ds_fail "the hook stayed without the pin"

# A series change takes the module of the fallback kernel along, when the archive has one.
commit_world series-keeps-fallback '{"mode": "all", "accept": ["series:nvidia=615-open"]}'
assert_eq "$K38+1" "$(version_of "$MODULE-615-open-7.0.0-38-generic")"
assert_eq "$K42" "$(version_of "$MODULE-615-open-7.0.0-42-generic")"
assert_eq "" "$(version_of "$MODULE-595-open-7.0.0-38-generic")"
assert_json "$ENGINE" '[.items[].code] | index("module-loss") == null'
# Without one the report says what goes.
commit_world new-series-nvidia '{"mode": "all", "accept": ["series:nvidia=615-open"]}'
assert_json "$ENGINE" '.items[] | select(.code == "module-loss") | .packages == ["linux-modules-nvidia-595-open-7.0.0-38-generic"]'
assert_json "$ENGINE" '[.items[].code] | index("driver-needs-reboot") != null'

# What cannot be kept for the way back is named, and what was kept before stays.
world_install driver-respin
engine_ok policy
sudo -n mkdir -p /var/cache/dotsteward/apt-rollback
sudo -n touch /var/cache/dotsteward/apt-rollback/example-kept_1.0_amd64.deb
sudo -n find /srv/world/repo/pool -name 'nvidia-utils-595_595.99.02*' -delete
engine_ok commit '{"mode": "all"}'
assert_json "$ENGINE" '.rollback.missing | map(startswith("nvidia-utils-595")) | any'
[[ -e /var/cache/dotsteward/apt-rollback/example-kept_1.0_amd64.deb ]] || ds_fail "a missing package cost the rollback cache what it had"

# The newest kernel has no module on disk: the report says do not reboot into it, whatever the run did.
world_modinfo "" all
world_install same-string
engine commit '{"mode": "all"}'
assert_eq 3 "$ENGINE_STATUS"
assert_json "$ENGINE" '.status == "committed" and ([.items[] | select(.code == "module-missing")] | length == 1)'
assert_json "$ENGINE" '.items[] | select(.code == "module-missing") | .kernel == "7.0.0-44-generic"'

world_modinfo "" 7.0.0-44-generic
world_install no-module-installed
engine commit '{"mode": "all"}'
assert_eq 3 "$ENGINE_STATUS"
assert_json "$ENGINE" '.status == "nothing" and (.items[] | select(.code == "module-missing") | .kernel == "7.0.0-44-generic")'
assert_json "$DOTSTEWARD_STATE_ROOT/review.json" '.items[] | select(.code == "module-missing") | .kernel == "7.0.0-44-generic"'

world_install image-above-meta
engine commit '{"mode": "all"}'
assert_eq 3 "$ENGINE_STATUS"
assert_eq "2.0-1" "$(version_of example-lib)"
assert_json "$ENGINE" '.status == "committed" and (.items[] | select(.code == "module-missing") | .kernel == "7.0.0-44-generic")'

world_modinfo "" 7.0.0-42-generic
world_install dkms-pull
engine commit '{"mode": "all"}'
assert_eq 3 "$ENGINE_STATUS"
assert_json "$ENGINE" '.status == "refused" and (.items[] | select(.code == "module-missing") | .kernel == "7.0.0-42-generic")'

