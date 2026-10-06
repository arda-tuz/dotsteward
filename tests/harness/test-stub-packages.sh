# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # dpkg-query format strings are literal
# The package stubs share one fake dpkg database and one fake APT index:
# dpkg-query, dpkg, dpkg-deb, apt-get and apt-cache.

ds_use_stubs sudo dpkg-query dpkg dpkg-deb apt-get apt-cache

# --- dpkg --compare-versions follows Debian ordering --------------------
compare() { dpkg --compare-versions "$1" "$2" "$3"; }
for case in \
  "1.0~rc1 lt 1.0" "1.0 gt 1.0~rc1" "1.0~~ lt 1.0~" "1:0.9 gt 2.0" "1.0-1 lt 1.0-2" \
  "1.10 gt 1.9" "1.0 eq 1.0-0" "1.0a gt 1.0" "1.0+b1 gt 1.0" "2.0 ge 2.0" "2.0 le 2.0" \
  "1.2.3 ne 1.2.4" "1.0 << 1.1" "1.1 >> 1.0" "1.0 <= 1.0" "1.0 >= 1.0" "1.0 = 1.0" \
  "0:1.0 eq 1.0" " lt 1.0" "1.0 lt-nl " "1.0 gt-nl 0.9"; do
  read -r -a parts <<<"$case"
  if ((${#parts[@]} == 2)); then
    # An empty version on the left or right side.
    if [[ $case == " "* ]]; then parts=("" "${parts[@]}"); else parts+=(""); fi
  fi
  compare "${parts[@]}" || ds_fail "dpkg --compare-versions $case should be true"
done
for case in "1.0 lt 1.0~rc1" "1:0.1 lt 2.0" "1.0 gt 1.0" "1.9 gt 1.10" "1.0 ne 1.0-0"; do
  read -r -a parts <<<"$case"
  if compare "${parts[@]}"; then ds_fail "dpkg --compare-versions $case should be false"; fi
done
assert_exit 2 dpkg --compare-versions 1.0 bogus 2.0
assert_contains "$DS_STDERR" "unknown"
assert_eq amd64 "$(dpkg --print-architecture)"
ds_stub_set dpkg architecture arm64
assert_eq arm64 "$(dpkg --print-architecture)"

# --- dpkg-query over the fake database ----------------------------------
ds_dpkg_installed example-app 1.2.3 amd64 "Files=/usr/bin/example-app /usr/share/doc/example-app"
assert_eq 1.2.3 "$(ds_dpkg_version example-app)"
assert_eq "" "$(ds_dpkg_version example-term)"
assert_eq 1.2.3 "$(dpkg-query -W -f='${Version}' example-app)"
assert_eq "install ok installed 1.2.3" "$(dpkg-query -W --showformat='${Status} ${Version}\n' example-app)"
assert_eq "ii |installed|example-app|amd64" "$(dpkg-query -W -f '${db:Status-Abbrev}|${db:Status-Status}|${binary:Package}|${Architecture}\n' example-app)"
assert_eq "example-app	1.2.3" "$(dpkg-query -W example-app)"
# A removed but not purged package keeps its Version in the database.
ds_dpkg_config_files example-removed 2.0.0
assert_eq "" "$(ds_dpkg_version example-removed)"
assert_eq "rc |deinstall|ok|config-files|2.0.0" "$(dpkg-query -W -f '${db:Status-Abbrev}|${db:Status-Want}|${db:Status-Eflag}|${db:Status-Status}|${Version}' example-removed)"
assert_eq "deinstall ok config-files" "$(dpkg-query -W -f '${Status}' example-removed)"
assert_exit 1 dpkg-query -W -f='${Version}' example-term
assert_eq "dpkg-query: no packages found matching example-term" "$DS_STDERR"
assert_exit 1 dpkg-query -W example-app example-term
assert_eq "example-app	1.2.3" "$DS_STDOUT"
dpkg-query -s example-app >"$TMPDIR/status"
assert_contains "$(<"$TMPDIR/status")" "Package: example-app
Status: install ok installed"
assert_contains "$(<"$TMPDIR/status")" "Version: 1.2.3"
assert_eq "example-app: /usr/bin/example-app" "$(dpkg-query -S /usr/bin/example-app)"
assert_exit 1 dpkg-query -S /usr/bin/nothing
assert_contains "$DS_STDERR" "no path found matching pattern /usr/bin/nothing"
assert_eq "/usr/bin/example-app
/usr/share/doc/example-app" "$(dpkg-query -L example-app)"
assert_eq "example-app: /usr/bin/example-app" "$(dpkg -S /usr/bin/example-app)"
assert_eq "1.2.3" "$(dpkg -s example-app | sed -n 's/^Version: //p')"

# --- dpkg-deb reads fake packages ---------------------------------------
ds_fake_deb "$TMPDIR/example-term_2.0.0_amd64.deb" example-term 2.0.0 amd64 "Maintainer=Example <maint@example.invalid>"
assert_eq example-term "$(dpkg-deb -f "$TMPDIR/example-term_2.0.0_amd64.deb" Package)"
assert_eq "Package: example-term
Version: 2.0.0" "$(dpkg-deb --field "$TMPDIR/example-term_2.0.0_amd64.deb" Package Version)"
assert_contains "$(dpkg-deb -f "$TMPDIR/example-term_2.0.0_amd64.deb")" "Maintainer: Example <maint@example.invalid>"
assert_eq "example-term	2.0.0" "$(dpkg-deb -W "$TMPDIR/example-term_2.0.0_amd64.deb")"
assert_contains "$(dpkg-deb -I "$TMPDIR/example-term_2.0.0_amd64.deb")" " Architecture: amd64"
printf 'not a package\n' >"$TMPDIR/broken.deb"
assert_exit 2 dpkg-deb -f "$TMPDIR/broken.deb" Package
assert_contains "$DS_STDERR" "is not a Debian format archive"
assert_exit 2 dpkg-deb -f "$TMPDIR/missing.deb" Package
# The committed fixture packages are fake packages too.
assert_eq example-app "$(dpkg-deb -f "$(ds_fixture common/debs/example-app_1.2.3_amd64.deb)" Package)"

# --- dpkg -i and -r need root rights ------------------------------------
assert_exit 2 dpkg -i "$TMPDIR/example-term_2.0.0_amd64.deb"
assert_contains "$DS_STDERR" "requires superuser privilege"
assert_eq "" "$(ds_dpkg_version example-term)"
sudo dpkg -i "$TMPDIR/example-term_2.0.0_amd64.deb" >/dev/null
assert_eq 2.0.0 "$(ds_dpkg_version example-term)"
sudo dpkg -r example-term >/dev/null
assert_eq "" "$(ds_dpkg_version example-term)"

# --- apt-get --------------------------------------------------------------
ds_apt_available example-term 2.1.0
ds_apt_available example-app 1.5.0
assert_exit 100 apt-get update
assert_contains "$DS_STDERR" "Permission denied"
: >"$DS_CALL_LOG"
assert_exit 0 sudo apt-get update
assert_calls "sudo apt-get update" "apt-get update"

# Unknown packages fail the whole transaction before anything is installed.
assert_exit 100 sudo apt-get install --no-install-recommends example-term missing-package
assert_contains "$DS_STDERR" "E: Unable to locate package missing-package"
assert_eq "" "$(ds_dpkg_version example-term)"

# One transaction installs names (index version) and package files.
ds_fake_deb "$TMPDIR/example-app_1.4.0_amd64.deb" example-app 1.4.0
sudo apt-get install --no-install-recommends example-term "$TMPDIR/example-app_1.4.0_amd64.deb" >/dev/null
assert_eq 2.1.0 "$(ds_dpkg_version example-term)"
assert_eq 1.4.0 "$(ds_dpkg_version example-app)"

# A pinned version must exist in the index.
assert_exit 100 sudo apt-get install -y example-term=9.9
assert_contains "$DS_STDERR" "Version '9.9' for 'example-term' was not found"
sudo apt-get install -y example-term=2.1.0 >/dev/null

# Downgrades are refused unless allowed.
ds_fake_deb "$TMPDIR/example-app_1.0.0_amd64.deb" example-app 1.0.0
assert_exit 100 sudo apt-get install -y "$TMPDIR/example-app_1.0.0_amd64.deb"
assert_contains "$DS_STDERR" "downgraded"
assert_eq 1.4.0 "$(ds_dpkg_version example-app)"
sudo apt-get install -y --allow-downgrades "$TMPDIR/example-app_1.0.0_amd64.deb" >/dev/null
assert_eq 1.0.0 "$(ds_dpkg_version example-app)"

# The index version is what gets installed, so a test can make the
# post-install verification fail by publishing an older version.
ds_apt_available example-term 1.0.0
sudo apt-get install -y --reinstall --allow-downgrades example-term >/dev/null
assert_eq 1.0.0 "$(ds_dpkg_version example-term)"

assert_exit 100 sudo apt-get install --no-such-flag example-term
assert_contains "$DS_STDERR" "Command line option"
assert_exit 0 sudo apt-get -o Dpkg::Options::=--force-confdef remove example-term
assert_eq "" "$(ds_dpkg_version example-term)"

# --- apt-cache ------------------------------------------------------------
ds_apt_available example-term 2.1.0
assert_eq "example-term:
  Installed: (none)
  Candidate: 2.1.0" "$(apt-cache policy example-term | head -n 3)"
assert_eq "example-app:
  Installed: 1.0.0
  Candidate: 1.5.0" "$(apt-cache policy example-app | head -n 3)"
assert_contains "$(apt-cache show example-term)" "Version: 2.1.0"
assert_exit 100 apt-cache show missing-package
assert_contains "$(apt-cache madison example-term)" "example-term | 2.1.0 |"
assert_exit 100 apt-cache bogus-operation
