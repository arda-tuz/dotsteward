# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# The pin file of the gated classes, /etc/apt/preferences.d/60dotsteward (design 10.3).
# `dotsteward e2e` on a Linux machine with dpkg (its status file) checks it in
# core:apt-files against what the apt engine would write from what dpkg has now
# (its read only `files` action). The one finding is a file there whose header
# or pairs are not that: the dpkg hook keeps the pairs at what dpkg has, so it
# did not run, or a hand edit. Everything the owner's own apt can bring is a
# warning: the rule (which classes the file holds) not yet what the next
# terminal `dotsteward upgrade` writes, a file there while the machine wants
# none, a file not there yet, an engine that cannot run or answers nonsense.
# The drop-in of unattended-upgrades is not checked here: the system component
# apt-policy owns it. Nothing of this changes the machine.
# shellcheck source=tests/cli/e2e/helpers.sh
source "$DS_REPO_ROOT/tests/cli/e2e/helpers.sh"

ds_use_stubs sudo dpkg dpkg-query
mkdir -p "$DS_SYSTEM_ROOT/var/lib/dpkg"
: >"$DS_SYSTEM_ROOT/var/lib/dpkg/status"
pin=$DS_SYSTEM_ROOT/etc/apt/preferences.d/60dotsteward
header='# Managed by dotsteward: gated classes stay as dpkg has them.'
pair=$'Package: src:linux-meta:any\nPin: version 6.8.0.1\nPin-Priority: 990\n'
rule=$'Package: src:linux-meta*:any\nPin: version *\nPin-Priority: -1\n'
pin_text="$header"$'\n'"$pair"$'\n'"$rule"

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
  jq -n --arg pin "$pin" --argjson text "$1" '{schema_version: 1, pin: {path: $pin, text: $text}}' \
    >"$DS_TEST_ROOT/apt-files.json"
}
answer "$(jq -n --arg text "$pin_text" '$text')"

assert_exit 0 run_e2e --list
assert_contains "$DS_STDOUT" "core:apt-files"

# Not there yet: a note, green.
assert_exit 0 run_e2e
assert_contains "$DS_STDERR" "core:apt-files: $pin is not there yet: the first 'dotsteward upgrade' on a terminal writes it"
assert_not_contains "$DS_STDERR" "unattended"
assert_json "$DS_TEST_ROOT/apt-request.json" '.gated == true'

# There with the bytes the engine would write: nothing to say.
mkdir -p "${pin%/*}"
printf '%s' "$pin_text" >"$pin"
assert_exit 0 run_e2e
assert_not_contains "$DS_STDERR" "core:apt-files"

# Another rule, as after the owner's own apt purge or install of a driver: a note, green.
printf '%s' "$header"$'\n'"$pair"$'\n'$'Package: src:linux-meta*:any src:nvidia-graphics-drivers-*:any\nPin: version *\nPin-Priority: -1\n' >"$pin"
assert_exit 0 run_e2e
assert_contains "$DS_STDERR" "core:apt-files: $pin holds back other classes than this machine has now: the next 'dotsteward upgrade' on a terminal sets it"

# Other pairs, or no header: the hook did not keep the file, a finding.
printf '%s' "$header"$'\n'$'Package: src:linux-meta:any\nPin: version 6.8.0.9\nPin-Priority: 990\n'$'\n'"$rule" >"$pin"
assert_exit 1 run_e2e --keep-going --json
assert_eq '[["core:apt-files","apt-file-mismatch","'"$pin"'"]]' "$(findings)"
assert_contains "$DS_STDERR" "$pin does not hold what dpkg has now: run 'dotsteward upgrade' on a terminal, which rewrites it"
printf '%s' "$pair"$'\n'"$rule" >"$pin"
assert_exit 1 run_e2e --keep-going --json
assert_eq '[["core:apt-files","apt-file-mismatch","'"$pin"'"]]' "$(findings)"
printf '%s' "$pin_text" >"$pin"

# [apt.gated] enable = false, or no gated class: a file that is there is a note.
answer null
assert_exit 0 run_e2e
assert_contains "$DS_STDERR" "core:apt-files: $pin is there, but this machine"
rm -f -- "$pin"
assert_exit 0 run_e2e
assert_not_contains "$DS_STDERR" "core:apt-files"

# An engine that cannot run, or answers what is not an answer, says so and stays green.
rm -f -- "$DS_TEST_ROOT/apt-files.json"
assert_exit 0 run_e2e
assert_contains "$DS_STDERR" "core:apt-files: the pin file was not checked:"
printf '[1, 2]\n' >"$DS_TEST_ROOT/apt-files.json"
assert_exit 0 run_e2e
assert_contains "$DS_STDERR" "core:apt-files: the pin file was not checked:"

# The file of the constraints and holds follows the intent and what dpkg has, both the owner's to
# change: missing, other bytes or unwanted, it is only ever a note.
kept=$DS_SYSTEM_ROOT/etc/apt/preferences.d/61dotsteward-kept
kept_text=$'# Managed by dotsteward: the version constraints and holds of the instance.\nPackage: example-server\nPin: version 16.*\nPin-Priority: 990\n'
answer_kept() {
  jq -n --arg pin "$pin" --arg ptext "$pin_text" --arg kept "$kept" --argjson text "$1" \
    '{schema_version: 1, pin: {path: $pin, text: $ptext}, kept: {path: $kept, text: $text}}' >"$DS_TEST_ROOT/apt-files.json"
}
printf '%s' "$pin_text" >"$pin"
answer_kept "$(jq -n --arg text "$kept_text" '$text')"
assert_exit 0 run_e2e
assert_json "$DS_TEST_ROOT/apt-request.json" '.kept == []'
assert_contains "$DS_STDERR" "core:apt-files: $kept is not there yet: the first 'dotsteward upgrade' on a terminal writes it"
printf '%s' "$kept_text" >"$kept"
assert_exit 0 run_e2e
assert_not_contains "$DS_STDERR" "core:apt-files"
printf 'Package: example-server\nPin: version 17.*\nPin-Priority: 990\n' >"$kept"
assert_exit 0 run_e2e --keep-going --json
assert_eq '[]' "$(findings)"
assert_contains "$DS_STDERR" "core:apt-files: $kept is not what the constraints and holds of the instance and dpkg say now"
answer_kept null
assert_exit 0 run_e2e
assert_contains "$DS_STDERR" "core:apt-files: $kept is there, but nothing of the instance constrains or holds a package here"
rm -f -- "$kept"
assert_exit 0 run_e2e
assert_not_contains "$DS_STDERR" "core:apt-files"

# Checks change nothing.
answer "$(jq -n --arg text "$pin_text" '$text')"
printf '%s' "$pin_text" >"$pin"
before=$(find "$DS_SYSTEM_ROOT" -printf '%p %s %T@\n' | LC_ALL=C sort)
assert_exit 0 run_e2e
assert_eq "$before" "$(find "$DS_SYSTEM_ROOT" -printf '%p %s %T@\n' | LC_ALL=C sort)"
assert_eq "0" "$(ds_call_count sudo)"
