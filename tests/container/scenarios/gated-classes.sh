# shellcheck shell=bash
# shellcheck disable=SC2024 # the log files belong to the test user, who writes them
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Inside the container: under the pin file every installed package of a gated Source has its
# installed version as candidate, with new versions in the archive, and no user of libapt
# moves one: apt, unattended-upgrades, PackageKit, aptdaemon. Control packages show that
# each of them works and keeps updating the rest. Only the engine moves the classes.
# shellcheck source=tests/container/scenarios/lib.sh
source "$DS_REPO_ROOT/tests/container/scenarios/lib.sh"
# shellcheck source=tests/apt-worlds/helpers.sh
source "$DS_REPO_ROOT/tests/apt-worlds/helpers.sh"

apt --version | head -n 1
sudo_open
world_modinfo
world_install bind
MODULE_44=linux-modules-nvidia-595-open-7.0.0-44-generic

# The comparison that gives this test its teeth: without the pin apt moves the classes. How far
# depends on the solver: the one of apt 3 keeps the driver back and still takes the new kernel.
without=$(apt-get -s full-upgrade 2>&1)
assert_contains "$without" "Inst linux-image-7.0.0-44-generic"
assert_contains "$without" "Inst example-lib"

engine_ok policy
assert_json "$ENGINE" '.pin.changed == true and .unattended.changed == true'
pin_matches_dpkg
assert_contains "$(</etc/apt/apt.conf.d/52dotsteward-unattended-upgrades)" 'Remove-Unused-Kernel-Packages "false"'
assert_contains "$(<"$PIN_HOOK")" "post-invoke="
before=$(gated_state)
[[ -n $before ]] || ds_fail "the world has no gated package"
candidates_stay

# The file changes nothing when it is right; a wrong file is repaired.
engine_ok policy
assert_json "$ENGINE" '.pin.changed == false and .unattended.changed == false'
printf 'Package: *\nPin: version *\nPin-Priority: 100\n' | sudo -n tee "$PIN" >/dev/null
engine_ok policy
assert_json "$ENGINE" '.pin.changed == true'
pin_matches_dpkg

controls_old() {
  local name
  for name in example-lib example-other example-tracked; do
    apt_root dpkg -i --force-downgrade "/srv/world/repo/pool/${name}_1.0-1_amd64.deb" >/dev/null 2>&1
    assert_eq "1.0-1" "$(version_of "$name")"
  done
}

controls_moved() {
  local name
  for name in example-lib example-other example-tracked; do
    assert_eq "2.0-1" "$(version_of "$name")" "$1 did not update $name"
  done
}

# --- apt

simulation=$(apt-get -s full-upgrade 2>&1)
assert_not_contains "$simulation" "Inst nvidia-"
assert_not_contains "$simulation" "Inst linux-"
assert_not_contains "$simulation" "Inst libnvidia-"
assert_not_contains "$simulation" "Remv "
assert_contains "$simulation" "Inst example-lib"
apt_root apt-get -y -q upgrade >"$out_dir/apt-upgrade.log" 2>&1
controls_moved "apt-get upgrade"
assert_eq "$before" "$(gated_state)" "apt-get upgrade"
controls_old
apt_root apt-get -y -q full-upgrade >"$out_dir/apt-full.log" 2>&1
controls_moved "apt-get full-upgrade"
assert_eq "$before" "$(gated_state)" "apt-get full-upgrade"
controls_old
# A series or a kernel by name has no candidate either.
status=0
apt_root apt-get -y -q install linux-image-7.0.0-44-generic "$MODULE_44" >"$out_dir/apt-install.log" 2>&1 || status=$?
assert_eq "$before" "$(gated_state)" "apt-get install by name"
status=0
apt_root apt-get -y -q install nvidia-driver-595-open >"$out_dir/apt-install-driver.log" 2>&1 || status=$?
assert_eq "$before" "$(gated_state)" "apt-get install of the driver"
apt_root apt-get -y -q --no-install-recommends autoremove >/dev/null 2>&1 || true

# --- unattended-upgrades, with its real configuration: it reads -security

if type -P unattended-upgrade >/dev/null; then
  dry=$(apt_root unattended-upgrade --dry-run --verbose 2>&1 || true)
  assert_contains "$dry" "example-lib"
  apt_root unattended-upgrade --verbose >"$out_dir/unattended.log" 2>&1 ||
    ds_fail "unattended-upgrade failed: $(tail -n 20 "$out_dir/unattended.log")"
  controls_moved "unattended-upgrade"
  assert_eq "$before" "$(gated_state)" "unattended-upgrade"
  controls_old
  printf 'exercised: unattended-upgrades\n'
else
  ds_fail "the image has no unattended-upgrade"
fi

system_bus

# --- PackageKit, through its own daemon

# Its client is pkcon, and pkgcli since Ubuntu 26.04.
if type -P pkcon >/dev/null; then
  pk_refresh=(pkcon refresh --noninteractive)
  pk_updates=(pkcon get-updates --noninteractive)
  pk_update=(pkcon update --noninteractive)
else
  pk_refresh=(pkgcli --yes refresh)
  pk_updates=(pkgcli list-updates)
  pk_update=(pkgcli --yes update)
fi
if sudo -n timeout 120 "${pk_refresh[@]}" >"$out_dir/pk-refresh.log" 2>&1; then
  updates=$(sudo -n timeout 120 "${pk_updates[@]}" 2>&1 || true)
  printf '%s\n' "$updates" >"$out_dir/pk-updates.log"
  assert_contains "$updates" "example-lib"
  assert_not_contains "$updates" "nvidia-"
  assert_not_contains "$updates" "linux-generic"
  assert_not_contains "$updates" "linux-image"
  sudo -n timeout 300 "${pk_update[@]}" >"$out_dir/pk-update.log" 2>&1 || true
  controls_moved "${pk_update[0]} update: $(tail -n 5 "$out_dir/pk-update.log")"
  assert_eq "$before" "$(gated_state)" "${pk_update[0]} update"
  controls_old
  printf 'exercised: PackageKit through %s\n' "${pk_update[0]}"
else
  printf 'NOT EXERCISED: PackageKit: %s\n' "$(tail -n 3 "$out_dir/pk-refresh.log" | tr '\n' ' ')"
fi

# --- aptdaemon, through its own daemon

if type -P aptdcon >/dev/null; then
  status=0
  yes | sudo -n timeout 300 aptdcon --hide-terminal --full-upgrade >"$out_dir/aptdcon.log" 2>&1 || status=$?
  if [[ $(version_of example-lib) == 2.0-1 ]]; then
    controls_moved "aptdcon"
    assert_eq "$before" "$(gated_state)" "aptdcon"
    controls_old
    printf 'exercised: aptdaemon\n'
  else
    assert_eq "$before" "$(gated_state)" "aptdcon"
    printf 'NOT EXERCISED: aptdaemon (status %s): %s\n' "$status" "$(tail -n 3 "$out_dir/aptdcon.log" | tr '\n' ' ')"
  fi
else
  printf 'NOT EXERCISED: aptdaemon: not in the archive of this release\n'
fi

# --- the engine moves them, and the pin follows

pin_before=$(<"$PIN")
engine_ok commit '{"mode": "tracked", "tracked": ["example-tracked"]}'
assert_json "$ENGINE" '.status == "committed"'
assert_eq "$K44" "$(version_of linux-generic-hwe-24.04)"
assert_eq "$K44" "$(version_of linux-image-7.0.0-44-generic)"
assert_eq "$K44" "$(version_of "$MODULE_44")"
assert_eq "$D106" "$(version_of nvidia-driver-595-open)"
assert_eq "$D106" "$(version_of libnvidia-gl-595:i386)"
assert_eq "2.0-1" "$(version_of example-tracked)"
assert_eq "1.0-1" "$(version_of example-other)" "tracked mode leaves the rest"
audit_clean
pin_matches_dpkg
candidates_stay
[[ $pin_before != "$(<"$PIN")" ]] || ds_fail "the pin did not follow dpkg"
assert_contains "$(<"$PIN")" "$K44"

# A second run has nothing left of the classes; the rest stays for the mode that wants it.
engine_ok commit '{"mode": "tracked", "tracked": ["example-tracked"]}'
assert_json "$ENGINE" '.status == "nothing"'

# The pin holds a new version that comes later too.
assert_not_contains "$(apt-get -s full-upgrade 2>&1)" "Inst linux-"
