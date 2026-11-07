# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Inside the container, the helpers of the scenarios (not a scenario). The user has a real
# sudo with a password; everything else is real too: apt, dpkg, D-Bus. No init runs here.
#
#   sudo_open              opens the sudo window, as a terminal would
#   system_bus             starts the D-Bus system bus; it activates polkit and the package
#                          daemons from their service files, as it does on a machine
#   world_install NAME     a clean machine in the base state of world NAME: real packages from
#                          its base suite, then the sources of the world
#   engine ACTION [JSON]   the engine through its internal command line: ENGINE is the answer,
#                          ENGINE_STATUS the exit code; --report goes to the state root
#   version_of NAME        the version dpkg has of NAME, empty when not installed
#   gated_state            name=version of every installed package of a gated Source
#   pin_matches_dpkg       the pin file holds exactly the (source, version) of dpkg
#   candidates_stay        under the pin every gated package has its installed version as candidate
#   modinfo_stub [SIGNER]  a modinfo that finds the module with this signer (default the
#                          distribution's); empty: it finds none. A container has no kernel modules
#   STATE                  the directory the hooks of the fixture packages look at

WORLDS_PY=$DS_REPO_ROOT/tests/apt-worlds/fixtures/worlds.py
CODENAME=$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")
STATE=/run/dotsteward-test
PIN=/etc/apt/preferences.d/60dotsteward
GATED_SOURCES='^(linux-meta|linux-restricted-modules|linux-restricted-signatures|nvidia-graphics-drivers-)'
# The harness points this at a synthetic file; the engine must see this machine.
unset DOTSTEWARD_OS_RELEASE
out_dir=$DS_TEST_ROOT/out
mkdir -p "$out_dir"
engine_runs=0

sudo_open() {
  # The word of the throwaway user of tests/container/setup.sh.
  printf 'container-test\n' | sudo -S -p '' -v
}

system_bus() {
  sudo -n mkdir -p /run/dbus
  sudo -n dbus-uuidgen --ensure
  sudo -n dbus-daemon --system --fork
}

apt_root() {
  sudo -n env DEBIAN_FRONTEND=noninteractive "$@"
}

world_clean() {
  local names
  names=$(dpkg-query -W -f='${binary:Package} ${Maintainer}\n' | awk '/maintainer@example.invalid/ {print $1}')
  if [[ -n $names ]]; then
    # shellcheck disable=SC2086 # one package per word
    apt_root dpkg --purge --force-all $names >/dev/null 2>&1 || true
  fi
  sudo -n rm -rf /srv/world "$STATE"
  sudo -n rm -f "$PIN" /etc/apt/apt.conf.d/52dotsteward-unattended-upgrades
  sudo -n rm -rf /var/cache/dotsteward
}

world_install() {
  local name=$1 wanted=()
  printf 'world %s\n' "$name"
  world_clean
  sudo -n mkdir -p "$STATE"
  sudo -n chmod 0777 "$STATE"
  sudo -n /usr/bin/python3 -I "$WORLDS_PY" build "$name" /srv/world --codename "$CODENAME" --debs
  sudo -n cp /srv/world/sources.base.list /etc/apt/sources.list
  apt_root apt-get update -qq
  mapfile -t wanted < <(/usr/bin/python3 -I "$WORLDS_PY" installed "$name")
  apt_root apt-get install -y -qq --no-install-recommends "${wanted[@]}" >"$out_dir/install.log" 2>&1 ||
    ds_fail "the base of world $name did not install: $(tail -n 20 "$out_dir/install.log")"
  sudo -n cp /srv/world/sources.world.list /etc/apt/sources.list
  apt_root apt-get update -qq
}

engine() {
  local action=$1 request=${2:-{\}}
  engine_runs=$((engine_runs + 1))
  ENGINE=$out_dir/$action.$engine_runs.json
  ENGINE_STATUS=0
  PYTHONPATH=$DS_REPO_ROOT/cli/python PYTHONDONTWRITEBYTECODE=1 python3 -s -P -m dotsteward_cli.apt_plan \
    "$action" --request - --report apt-test <<<"$request" >"$ENGINE" 2>"$ENGINE.err" || ENGINE_STATUS=$?
}

engine_ok() {
  engine "$@"
  assert_eq 0 "$ENGINE_STATUS" "engine $1: $(tail -n 20 "$ENGINE.err"): $(jq -c '{status, items, recovery, message}' "$ENGINE" 2>/dev/null)"
}

version_of() {
  { dpkg-query -W -f='${db:Status-Abbrev}${Version}\n' "$1" 2>/dev/null || true; } | awk '/^ii/ {sub(/^ii */, ""); print}'
}

gated_state() {
  dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package} ${Version} ${source:Package}\n' |
    awk -v re="$GATED_SOURCES" '$1 == "ii" && $4 ~ re {print $2 "=" $3}' | LC_ALL=C sort
}

# Also what is unpacked and not yet configured: that version is on the disk, and is the one to keep.
dpkg_pairs() {
  dpkg-query -W -f='${db:Status-Abbrev} ${source:Package} ${Version}\n' |
    awk -v re="$GATED_SOURCES" '$1 ~ /^i/ && $2 ~ re {print $2 " " $3}' | LC_ALL=C sort -u
}

pin_pairs() {
  awk '/^Package: src:/ && !/\*/ {sub(/^Package: src:/, ""); sub(/:any$/, ""); source = $0} /^Pin: version / && source != "" {print source " " $3; source = ""}' "$PIN" |
    LC_ALL=C sort -u
}

pin_matches_dpkg() {
  assert_eq "$(dpkg_pairs)" "$(pin_pairs)" "the pin file tells what dpkg has"
  assert_contains "$(<"$PIN")" "Pin-Priority: -1"
  assert_file_mode "$PIN" 644
}

candidates_stay() {
  local entry name policy installed candidate
  while IFS= read -r entry; do
    name=${entry%%=*}
    policy=$(apt-cache policy "$name")
    installed=$(awk '/Installed:/ {print $2}' <<<"$policy")
    candidate=$(awk '/Candidate:/ {print $2}' <<<"$policy")
    assert_eq "$installed" "$candidate" "the candidate of $name under the pin"
  done < <(gated_state)
}

modinfo_stub() {
  local signer=${1-Canonical Ltd. Kernel Module Signing}
  mkdir -p "$DS_TEST_ROOT/bin"
  if [[ -n $signer ]]; then
    printf '#!/bin/sh\necho "%s"\n' "$signer" >"$DS_TEST_ROOT/bin/modinfo"
  else
    printf '#!/bin/sh\nexit 1\n' >"$DS_TEST_ROOT/bin/modinfo"
  fi
  chmod +x "$DS_TEST_ROOT/bin/modinfo"
  case :$PATH: in
    *":$DS_TEST_ROOT/bin:"*) ;;
    *) export PATH=$DS_TEST_ROOT/bin:$PATH ;;
  esac
}

# The journal of a dpkg that was killed takes root to read.
audit() {
  sudo -n dpkg --audit
}

audit_clean() {
  assert_eq "" "$(audit)" "dpkg --audit"
}
