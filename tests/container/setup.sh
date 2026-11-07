#!/usr/bin/env bash
# Runs once inside a fresh ubuntu container and makes the image of tests/container/run.sh: a
# disposable machine for the apt engine, without an init system, with a user with a password for
# sudo and the programs that use libapt and that the pin of the gated classes has to bind. Only
# the fixture repositories stay in its sources. Nothing here runs on a real machine.
set -Eeuo pipefail

[[ -f /.dockerenv ]] || {
  printf 'setup.sh: this belongs in a disposable container\n' >&2
  exit 1
}
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  dbus sudo python3-apt curl git ca-certificates jq procps lsb-release \
  kmod unattended-upgrades packagekit >/dev/null
# The client of PackageKit is in the package above since Ubuntu 26.04 (pkgcli), before in its own.
apt-get install -y -qq --no-install-recommends packagekit-tools >/dev/null 2>&1 || type -P pkgcli >/dev/null
apt-get install -y -qq --no-install-recommends aptdaemon >/dev/null 2>&1 ||
  printf 'setup.sh: this release has no aptdaemon\n'
# The CLI needs Python 3.11 (it brings its own from Nix on a real machine); the engine stays on
# the system's /usr/bin/python3, Python 3.10 on Ubuntu 22.04.
if [[ $(/usr/bin/python3 -c 'import sys; print(sys.version_info >= (3, 11))') == False ]]; then
  apt-get install -y -qq --no-install-recommends python3.11 >/dev/null
  ln -s /usr/bin/python3.11 /usr/local/bin/python3
fi
dpkg --add-architecture i386
rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*
rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin /var/cache/apt/archives/*.deb

useradd --create-home --shell /bin/bash tester
printf 'tester:container-test\n' | chpasswd
printf 'tester ALL=(ALL:ALL) ALL\nDefaults:tester timestamp_type=global\n' >/etc/sudoers.d/tester
chmod 0440 /etc/sudoers.d/tester
