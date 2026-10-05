# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# sudo: records argv, drops its own options, runs the command as the test
# user with system paths moved under DS_SYSTEM_ROOT, and marks the child as
# running with root rights for the other stubs.

ds_use_stubs sudo id

# A system file write lands in the fixture root.
printf 'KEY=value\n' >"$TMPDIR/default-file"
sudo install -m 0644 "$TMPDIR/default-file" /etc/default/example-app
assert_eq "KEY=value" "$(<"$DS_SYSTEM_ROOT/etc/default/example-app")"
assert_file_mode "$DS_SYSTEM_ROOT/etc/default/example-app" 0644
[[ ! -e /etc/default/example-app ]] || ds_fail "the real system path was written"

# Options of sudo itself are recorded but not passed on; NAME=value sets the
# environment of the command; "--" ends the options.
: >"$DS_CALL_LOG"
out=$(sudo -n -E -H -u root --preserve-env=PATH EXAMPLE_FLAG=on -- bash -c 'printf "%s|%s" "$EXAMPLE_FLAG" "$1"' bash /opt/example-app/bin)
assert_eq "on|$DS_SYSTEM_ROOT/opt/example-app/bin" "$out"
assert_calls "sudo -n -E -H -u root --preserve-env=PATH EXAMPLE_FLAG=on -- bash -c printf\\ \\\"%s\\|%s\\\"\\ \\\"\\\$EXAMPLE_FLAG\\\"\\ \\\"\\\$1\\\" bash /opt/example-app/bin"

# Rewritten prefixes, including OPTION=PATH arguments; other paths stay.
out=$(sudo printf '%s\n' /etc/shells /var/lib/x /usr/local/bin/x /usr/share/x /usr/lib/x \
  /srv/x /Applications/X.app /Library/X --target=/etc/apt/keyrings/k.gpg \
  /usr/bin/env /bin/sh /etc "$HOME/.zshrc" relative/etc/x)
assert_eq "$DS_SYSTEM_ROOT/etc/shells
$DS_SYSTEM_ROOT/var/lib/x
$DS_SYSTEM_ROOT/usr/local/bin/x
$DS_SYSTEM_ROOT/usr/share/x
$DS_SYSTEM_ROOT/usr/lib/x
$DS_SYSTEM_ROOT/srv/x
$DS_SYSTEM_ROOT/Applications/X.app
$DS_SYSTEM_ROOT/Library/X
--target=$DS_SYSTEM_ROOT/etc/apt/keyrings/k.gpg
/usr/bin/env
/bin/sh
$DS_SYSTEM_ROOT/etc
$HOME/.zshrc
relative/etc/x" "$out"

# The child sees root rights through the id stub; the caller does not.
assert_eq 1000 "$(id -u)"
assert_eq 0 "$(sudo id -u)"
assert_eq root "$(sudo id -un)"

# Credential handling options without a command succeed and do nothing.
assert_exit 0 sudo -v
assert_exit 0 sudo -k
assert_exit 0 sudo -n true

# Usage errors and a denied password are reported like sudo does.
assert_exit 1 sudo
assert_contains "$DS_STDERR" "usage: sudo"
assert_exit 1 sudo -u
assert_contains "$DS_STDERR" "option requires an argument"
ds_stub_route sudo '*' --exit 1 --stderr "sudo: a password is required"
assert_exit 1 sudo -n true
assert_eq "sudo: a password is required" "$DS_STDERR"

# The exit status of the command propagates.
ds_stub_clear_routes sudo
assert_exit 5 sudo bash -c 'exit 5'
