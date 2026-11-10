# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# The two apt files of the gated classes (design 10.3): the pin file
# /etc/apt/preferences.d/60dotsteward and
# /etc/apt/apt.conf.d/52dotsteward-unattended-upgrades. `dotsteward e2e` on a
# Linux machine with dpkg checks them in core:apt-files against what the apt
# engine would write from what dpkg has now (its read only `files` action):
# a file that is there must have those bytes, else a finding; a file that is
# not there yet is a note with the step that installs it (the first
# `dotsteward upgrade` on a terminal), and the run stays green; with
# `[apt.gated] enable = false` the pin file must not be there. An engine that
# cannot run is a note. Nothing of this changes the machine.
# shellcheck source=tests/cli/e2e/helpers.sh
source "$DS_REPO_ROOT/tests/cli/e2e/helpers.sh"

ds_use_stubs sudo dpkg dpkg-query
pin=$DS_SYSTEM_ROOT/etc/apt/preferences.d/60dotsteward
unattended=$DS_SYSTEM_ROOT/etc/apt/apt.conf.d/52dotsteward-unattended-upgrades
pin_text=$'# Managed by dotsteward: gated classes stay as dpkg has them.\n\nPackage: src:linux-meta*:any\nPin: version *\nPin-Priority: -1\n'
unattended_text=$'// Managed by dotsteward: no automatic removal of kernels and dependencies.\n'

# The apt engine as the tests run it: the answer of `files` from a file, and
# the request it got next to it.
engine=$DS_TEST_ROOT/apt-python
cat >"$engine" <<ENGINE
#!$BASH
cat >"$DS_TEST_ROOT/apt-request.json"
[[ \$3 == files ]] || exit 9
[[ -e $DS_TEST_ROOT/apt-files.json ]] || { printf 'ModuleNotFoundError: No module named apt\n' >&2; exit 1; }
cat -- "$DS_TEST_ROOT/apt-files.json"
ENGINE
chmod 0755 "$engine"
export DOTSTEWARD_APT_PYTHON=$engine
answer() {
  jq -n --arg pin "$pin" --arg unattended "$unattended" --argjson pin_text "$1" --arg unattended_text "$unattended_text" '{
    schema_version: 1,
    pin: {path: $pin, text: $pin_text},
    unattended: {path: $unattended, text: $unattended_text}}' >"$DS_TEST_ROOT/apt-files.json"
}
answer "$(jq -n --arg text "$pin_text" '$text')"

assert_exit 0 run_e2e --list
assert_contains "$DS_STDOUT" "core:apt-files"

# Neither file is there yet: two notes, green.
assert_exit 0 run_e2e
assert_contains "$DS_STDERR" "core:apt-files: $pin is not there yet: the first 'dotsteward upgrade' on a terminal writes it"
assert_contains "$DS_STDERR" "core:apt-files: $unattended is not there yet: the first 'dotsteward upgrade' on a terminal writes it"
assert_json "$DS_TEST_ROOT/apt-request.json" '.gated == true'

# Both there with the bytes the engine would write: nothing to say.
mkdir -p "${pin%/*}" "${unattended%/*}"
printf '%s' "$pin_text" >"$pin"
printf '%s' "$unattended_text" >"$unattended"
before=$(find "$DS_SYSTEM_ROOT" -printf '%p %s %T@\n' | LC_ALL=C sort)
assert_exit 0 run_e2e
assert_not_contains "$DS_STDERR" "core:apt-files"

# Other bytes: a finding for each file, which names the step that rewrites it.
printf 'Package: src:linux-meta*:any\nPin: version 6.8.*\nPin-Priority: 990\n' >"$pin"
printf '// by hand\n' >>"$unattended"
assert_exit 1 run_e2e --keep-going --json
assert_eq '[["core:apt-files","apt-file-mismatch","'"$pin"'"],["core:apt-files","apt-file-mismatch","'"$unattended"'"]]' "$(findings)"
assert_contains "$DS_STDERR" "$pin does not hold what dpkg has now: run 'dotsteward upgrade' on a terminal, which rewrites it"
printf '%s' "$unattended_text" >"$unattended"

# [apt.gated] enable = false: no pin file wanted, so one that is there is a finding.
answer null
assert_exit 1 run_e2e --keep-going --json
assert_eq '[["core:apt-files","apt-file-unwanted","'"$pin"'"]]' "$(findings)"
rm -f -- "$pin"
assert_exit 0 run_e2e
assert_not_contains "$DS_STDERR" "core:apt-files"

# An engine that cannot run says so and stays green.
rm -f -- "$DS_TEST_ROOT/apt-files.json"
assert_exit 0 run_e2e
assert_contains "$DS_STDERR" "core:apt-files: the apt files were not checked:"

# Checks change nothing.
answer "$(jq -n --arg text "$pin_text" '$text')"
printf '%s' "$pin_text" >"$pin"
before=$(find "$DS_SYSTEM_ROOT" -printf '%p %s %T@\n' | LC_ALL=C sort)
assert_exit 0 run_e2e
assert_eq "$before" "$(find "$DS_SYSTEM_ROOT" -printf '%p %s %T@\n' | LC_ALL=C sort)"
assert_eq "0" "$(ds_call_count sudo)"
