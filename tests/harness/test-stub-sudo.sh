# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# sudo: records argv, drops its own options, runs the command as the test
# user with system paths moved under DS_SYSTEM_ROOT, and marks the child as
# running with root rights for the other stubs.

ds_use_stubs sudo id dscl

# A system file write lands in the fixture root.
printf 'KEY=value\n' >"$TMPDIR/default-file"
sudo install -m 0644 "$TMPDIR/default-file" /etc/default/example-app
assert_eq "KEY=value" "$(<"$DS_SYSTEM_ROOT/etc/default/example-app")"
assert_file_mode "$DS_SYSTEM_ROOT/etc/default/example-app" 0644
[[ ! -e /etc/default/example-app ]] || ds_fail "the real system path was written"

# The test user cannot hand a file to root, so install's ownership options
# are dropped before the command runs; the call log keeps them, and the mode
# and every other option still apply.
src=$TMPDIR/default-file
: >"$DS_CALL_LOG"
sudo install -o root -g root -m 0644 "$src" /etc/shells
assert_eq "KEY=value" "$(<"$DS_SYSTEM_ROOT/etc/shells")"
assert_file_mode "$DS_SYSTEM_ROOT/etc/shells" 0644
sudo install -D -o root -g root -m 0644 "$src" /etc/default/new-dir/example-app
assert_eq "KEY=value" "$(<"$DS_SYSTEM_ROOT/etc/default/new-dir/example-app")"
assert_file_mode "$DS_SYSTEM_ROOT/etc/default/new-dir/example-app" 0644
assert_calls "sudo install -o root -g root -m 0644 $(printf %q "$src") /etc/shells" \
  "sudo install -D -o root -g root -m 0644 $(printf %q "$src") /etc/default/new-dir/example-app"

# Every spelling of the ownership options: separate, attached, long, long
# with "=", inside a cluster with the value next or attached, by full path,
# and after the operands.
sudo install -Do root -g root -m 0600 "$src" /etc/default/spelled/one
assert_file_mode "$DS_SYSTEM_ROOT/etc/default/spelled/one" 0600
sudo install -Doroot -groot -m0640 "$src" /etc/default/spelled/two
assert_file_mode "$DS_SYSTEM_ROOT/etc/default/spelled/two" 0640
sudo install --owner root --group=root --mode=0604 -D "$src" /etc/default/spelled/three
assert_file_mode "$DS_SYSTEM_ROOT/etc/default/spelled/three" 0604
sudo install --owner=root --group root -Dm 0644 "$src" /etc/default/spelled/four
assert_file_mode "$DS_SYSTEM_ROOT/etc/default/spelled/four" 0644
sudo "$(command -v install)" -vDgroot -o root "$src" /etc/default/spelled/five >/dev/null
assert_eq "KEY=value" "$(<"$DS_SYSTEM_ROOT/etc/default/spelled/five")"
sudo install -m 0644 "$src" /etc/default/spelled/six -o root -g root
assert_file_mode "$DS_SYSTEM_ROOT/etc/default/spelled/six" 0644

# Directories and target directories work the same way.
sudo install -d -o root -g root -m 0750 /etc/example-app/conf.d
assert_file_mode "$DS_SYSTEM_ROOT/etc/example-app/conf.d" 0750
sudo install -o root -g root -m 0644 -t /etc/example-app/conf.d "$src"
assert_file_mode "$DS_SYSTEM_ROOT/etc/example-app/conf.d/default-file" 0644

# After "--" every word is an operand and is passed on unchanged; a missing
# option value is left for install to report.
assert_exit 1 sudo install -m 0644 -- "$src" -o /etc/default/spelled/seven
assert_exit 1 sudo install -m 0644 "$src" /etc/default/spelled/eight -o
assert_contains "$DS_STDERR" "option requires an argument"

# chown and chgrp change nothing and succeed when every file exists below
# the fixture root; a missing file or operand fails like the real tools.
: >"$DS_CALL_LOG"
mtime=$(stat -c %Y:%Z "$DS_SYSTEM_ROOT/etc/shells")
assert_exit 0 sudo chown root:root /etc/shells
assert_exit 0 sudo chown -R -h --from=0 root /etc/example-app /etc/default/spelled/one
assert_exit 0 sudo chown --reference=/etc/shells -- /etc/default/new-dir/example-app
assert_exit 0 sudo /usr/bin/chgrp -R root /etc/example-app
assert_eq "$mtime" "$(stat -c %Y:%Z "$DS_SYSTEM_ROOT/etc/shells")"
assert_eq 4 "$(ds_call_count sudo)"
assert_exit 1 sudo chown root:root /etc/missing-file
assert_contains "$DS_STDERR" "chown: cannot access '/etc/missing-file': No such file or directory"
assert_exit 1 sudo chgrp root /etc/shells /etc/missing-file
assert_contains "$DS_STDERR" "chgrp: cannot access '/etc/missing-file'"
assert_exit 1 sudo chown --reference=/etc/missing-file /etc/shells
assert_contains "$DS_STDERR" "/etc/missing-file"
assert_exit 1 sudo chown root
assert_contains "$DS_STDERR" "chown: missing operand"

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

# The areas a user can write on a real host are moved below the fixture root
# too, so no path given to sudo reaches the host; only the test root itself
# (HOME and TMPDIR included) is left in place.
out=$(sudo printf '%s\n' /home/example/x /root/x /tmp/x /tmp /run/user/1000 /dev/shm/x \
  /mnt/x /media/x /private/tmp/x /Volumes/X /Users/example/x --dir=/tmp/x /dev/null)
assert_eq "$DS_SYSTEM_ROOT/home/example/x
$DS_SYSTEM_ROOT/root/x
$DS_SYSTEM_ROOT/tmp/x
$DS_SYSTEM_ROOT/tmp
$DS_SYSTEM_ROOT/run/user/1000
$DS_SYSTEM_ROOT/dev/shm/x
$DS_SYSTEM_ROOT/mnt/x
$DS_SYSTEM_ROOT/media/x
$DS_SYSTEM_ROOT/private/tmp/x
$DS_SYSTEM_ROOT/Volumes/X
$DS_SYSTEM_ROOT/Users/example/x
--dir=$DS_SYSTEM_ROOT/tmp/x
/dev/null" "$out"

# A write to such an area lands in the fixture root and never on the host.
probe=$(basename -- "$DS_TEST_ROOT")-sudo-probe
ds_defer rm -rf -- "/tmp/$probe"
sudo mkdir -p "/tmp/$probe" "/home/$probe/x"
sudo touch "/tmp/$probe/file"
[[ -d $DS_SYSTEM_ROOT/tmp/$probe && -f $DS_SYSTEM_ROOT/tmp/$probe/file ]] ||
  ds_fail "sudo mkdir/touch below /tmp did not land in the fixture root"
[[ -d $DS_SYSTEM_ROOT/home/$probe/x ]] ||
  ds_fail "sudo mkdir below /home did not land in the fixture root"
[[ ! -e /tmp/$probe && ! -e /home/$probe ]] || ds_fail "sudo wrote to the host"

# Paths inside the test root stay where they are.
sudo touch "$TMPDIR/written-by-root" "$HOME/written-by-root"
[[ -f $TMPDIR/written-by-root && -f $HOME/written-by-root ]] ||
  ds_fail "sudo moved a path inside the test root"

# dscl takes /Users/<name> as a record path, not a file: it is passed on
# unchanged and still updates the user database.
sudo dscl . -create "/Users/$USER" UserShell /bin/zsh
assert_eq /bin/zsh "$(ds_passwd_field "$USER" 7)"

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
