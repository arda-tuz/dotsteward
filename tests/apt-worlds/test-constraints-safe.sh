# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The records of the constraints and holds only ever lower a version, never raise one: what is
# outside a constraint, or not of the held version line, drops to -1, and everything inside keeps
# the priority of its origin. So a prerelease of -proposed or a version of an origin the owner turned
# off stays what the owner made it, with or without the records; a version asked for by name still
# installs. A shared library, which another package outside the component needs in another series,
# gets no record and a note, so the owner's other major still installs and upgrades. A hold keeps the
# installed upstream version and takes its Debian revisions. An epoch and a + version are inside
# their series; a constraint that is no series is refused, one that no version matches is said, a
# rule with a line break never reaches the file, and firmware is no package a rule binds.
# shellcheck source=tests/apt-worlds/helpers.sh
source "$DS_REPO_ROOT/tests/apt-worlds/helpers.sh"
world_require

KEPT='{"kept": [
  {"component": "sampledbms", "kind": "constraint", "version": "16", "reason": "the clusters run on 16",
   "packages": ["sampledbms-16", "samplecli", "sampledbms-lib"]},
  {"component": "sampleapp", "kind": "hold", "version": "2.0-1", "reason": "E2E red: sampleapp:start",
   "packages": ["sampleapp", "linux-firmware"]},
  {"component": "sampleepoch", "kind": "constraint", "version": "27", "reason": "stay on 27",
   "packages": ["sampleepoch"]},
  {"component": "sampleplus", "kind": "constraint", "version": "1.2", "reason": "the 1.2 format",
   "packages": ["sampleplus"]},
  {"component": "sampleother", "kind": "constraint", "version": "9", "reason": "a series it never had",
   "packages": ["sampleother"]},
  {"component": "samplesemver", "kind": "constraint", "version": "^16", "reason": "semver style",
   "packages": ["samplecli"]},
  {"component": "sampleline", "kind": "hold", "version": "2.0-1\n\nPackage: *\nPin: release a=*\nPin-Priority: 1001", "reason": "x",
   "packages": ["sampleapp"]}
]}'
policy() {
  POLICY=$DS_TEST_ROOT/out/policy.json
  APT_CONFIG=$WORLD/apt.conf DOTSTEWARD_APT_SUDO='' ds_python dotsteward_cli.apt_plan policy --request - \
    <<<"$1" >"$POLICY" 2>"$DS_TEST_ROOT/policy.err" || ds_fail "policy failed: $(<"$DS_TEST_ROOT/policy.err")"
}
candidate() {
  APT_CONFIG=$WORLD/apt.conf apt-cache policy "$1" | awk '/Candidate:/ {print $2}'
}
priority_of() {
  APT_CONFIG=$WORLD/apt.conf apt-cache policy "$1" |
    awk -v version="$2" '$1 == version { print $2; exit } $1 == "***" && $2 == version { print $3; exit }'
}
item() {
  assert_json "$POLICY" "[.items[] | select(.code == \"$1\" $2)] | length == 1" "item $1 $2"
}

world_up constraints-safe
codename=$(sed -n 's/^Codename: //p' "$WORLD"/repo/dists/*-updates/Release | head -n 1)
owner=$WORLD/etc/apt/preferences.d/00owner
printf 'Package: *\nPin: release a=%s-proposed\nPin-Priority: 100\n\nPackage: *\nPin: release o=Example Vendor\nPin-Priority: -1\n' \
  "$codename" >"$owner"
assert_eq 16.16-1 "$(candidate sampledbms-16)" "the owner's own origin pins, before any record"
proposed_before=$(priority_of sampledbms-16 16.19~rc1-1)
vendor_before=$(priority_of sampledbms-16 16.18-1)

policy "$KEPT"
kept=$WORLD/etc/apt/preferences.d/61dotsteward-kept
[[ -e $kept ]] || ds_fail "no file"
# Only lowered, never raised: the origins keep their priorities.
assert_not_contains "$(<"$kept")" "Pin-Priority: 990"
assert_eq 16.16-1 "$(candidate sampledbms-16)" "no prerelease of -proposed, no version of a turned off origin"
assert_eq "$proposed_before" "$(priority_of sampledbms-16 16.19~rc1-1)"
assert_eq "$vendor_before" "$(priority_of sampledbms-16 16.18-1)"
assert_eq 16.16-1 "$(candidate samplecli)" "outside the constraint is lowered"
assert_contains "$(APT_CONFIG=$WORLD/apt.conf apt-get -s install samplecli=17.2-1 2>&1)" "Inst samplecli [16.15-1] (17.2-1"
printf 'Package: *\nPin: release a=%s-proposed\nPin-Priority: -1\n\nPackage: *\nPin: release o=Example Vendor\nPin-Priority: -1\n' \
  "$codename" >"$owner"
assert_eq 16.16-1 "$(candidate sampledbms-16)" "the owner turned -proposed off as well"
assert_not_contains "$(APT_CONFIG=$WORLD/apt.conf apt-get -s upgrade 2>&1)" "16.19~rc1"

# A shared library: no record, a note, and the owner's other major upgrades and installs.
item constraint-shared 'and .package == "sampledbms-lib" and .pending == false'
assert_not_contains "$(<"$kept")" "sampledbms-lib"
upgrade=$(APT_CONFIG=$WORLD/apt.conf apt-get -s upgrade 2>&1)
assert_contains "$upgrade" "Inst sampledbms-17 [17.11-1] (17.12-1"
assert_not_contains "$upgrade" "kept back"

# A hold keeps the installed upstream version line and takes its Debian revisions.
assert_eq 1.0-2 "$(candidate sampleapp)"
assert_contains "$(APT_CONFIG=$WORLD/apt.conf apt-get -s install sampleapp=2.0-1 2>&1)" "Inst sampleapp"

# An epoch and a + version are inside their series.
assert_eq 5:27.3.2-1 "$(candidate sampleepoch)"
assert_eq 1.2+dfsg-2 "$(candidate sampleplus)"

# A series no version has is said; a constraint that is no series is refused; a line break never
# reaches the file; firmware is never bound.
item constraint-matches-nothing 'and .component == "sampleother"'
item kept-invalid 'and .component == "samplesemver"'
item kept-invalid 'and .component == "sampleline"'
assert_not_contains "$(<"$kept")" "release a=*"
assert_not_contains "$(<"$kept")" "Pin-Priority: 1001"
assert_not_contains "$(<"$kept")" "linux-firmware"
assert_eq 20240318.git3b128b60-0ubuntu2.27 "$(candidate linux-firmware)"

# The header says where the rules come from.
assert_contains "$(head -n 1 "$kept")" "hosts/<name>.toml"

# The plan of the engine reads the same records.
world_plan constraints-safe "$KEPT"
assert_json "$PLAN" '[.changes.upgrade[] | select(.name == "sampledbms-16") | .version] == ["16.16-1"]'
assert_json "$PLAN" '[.changes.upgrade[] | select(.name == "sampledbms-17") | .version] == ["17.12-1"]'
assert_json "$PLAN" '[.items[] | select(.code == "kept-back")] | length == 0'
