# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The systemctl stub keeps what a test reads from a real machine: enable
# links a unit into the wants directory of its WantedBy= below the fixture
# root, a missing unit file and missing root rights are refused, and what
# needs a running systemd fails without DS_SYSTEM_ROOT/run/systemd/system.

ds_use_stubs sudo systemctl

units=$DS_SYSTEM_ROOT/etc/systemd/system
mkdir -p "$units"
printf '[Timer]\nOnCalendar=daily\n\n[Install]\nWantedBy=timers.target\n' >"$units/example-app.timer"

# Without root rights nothing changes.
assert_exit 1 systemctl enable example-app.timer
assert_contains "$DS_STDERR" "Failed to enable unit: Access denied"
assert_exit 1 systemctl is-enabled example-app.timer
assert_eq "disabled" "$DS_STDOUT"

# Offline: enable works, --now and daemon-reload need a running systemd.
assert_exit 1 sudo systemctl daemon-reload
assert_contains "$DS_STDERR" "System has not been booted with systemd as init system"
assert_exit 1 sudo systemctl enable --now example-app.timer
[[ ! -e $units/timers.target.wants/example-app.timer ]] || ds_fail "a refused enable linked the unit"
assert_exit 0 sudo systemctl enable example-app.timer
assert_symlink_to "$units/timers.target.wants/example-app.timer" "$units/example-app.timer"
assert_exit 0 systemctl is-enabled example-app.timer
assert_eq "enabled" "$DS_STDOUT"
assert_exit 3 systemctl is-active example-app.timer
assert_eq "inactive" "$DS_STDOUT"

# A unit file that does not exist is refused.
mkdir -p "$DS_SYSTEM_ROOT/run/systemd/system"
assert_exit 1 sudo systemctl enable example-term.timer
assert_contains "$DS_STDERR" "Failed to enable unit: Unit file example-term.timer does not exist."
assert_exit 1 sudo systemctl start example-term.service
assert_contains "$DS_STDERR" "Failed to start unit: Unit file example-term.service does not exist."

# With a running systemd: --now starts the unit, disable --now stops it.
assert_exit 0 sudo systemctl daemon-reload
assert_exit 0 sudo systemctl enable --now example-app.timer
assert_exit 0 systemctl is-active example-app.timer
assert_eq "active" "$DS_STDOUT"
assert_exit 0 sudo systemctl disable --now example-app.timer
[[ ! -e $units/timers.target.wants/example-app.timer ]] || ds_fail "disable left the link"
assert_exit 3 systemctl is-active example-app.timer

assert_exit 1 systemctl reticulate
assert_contains "$DS_STDERR" "Unknown command verb reticulate."
assert_eq "3" "$(ds_call_count systemctl 'is-active *')"
