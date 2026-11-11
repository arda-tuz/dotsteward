# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The version constraints and holds of the instance bind what dotsteward itself does with apt, never
# the owner's own apt: no preferences file is written, and every candidate of `apt-cache policy`
# stays what the owner's pins and the archive make it. In the depcache of the engine (plan, commit,
# analysis) a package of the component takes the newest version inside its rule from the origins apt
# trusts as much as the newest one (no prerelease of -proposed, no backport, no origin the owner
# turned off); when there is none it stays, and the newer one waits (`constraint-waits`). A package
# the owner took out of its rule stays as it is, with a note, never undone. A library another
# package needs in a version outside the rule (Depends, a versioned Provides, Breaks) is not bound. A
# hold keeps what is below its version; an epoch is inside its series; an exact version is that
# version alone; a rule that is no series, no version or matches nothing is said, and firmware and
# the gated classes are never bound.
# shellcheck source=tests/apt-worlds/helpers.sh
source "$DS_REPO_ROOT/tests/apt-worlds/helpers.sh"
world_require

KEPT='{"kept": [
  {"component": "sampledbms", "kind": "constraint", "version": "16", "reason": "the clusters run on 16",
   "packages": ["sampledbms-16", "samplecli", "sampledbms-lib", "linux-generic-hwe-24.04"]},
  {"component": "sampleapp", "kind": "hold", "version": "2.0-1", "reason": "E2E red: sampleapp:start",
   "packages": ["sampleapp", "linux-firmware"]},
  {"component": "sampleepoch", "kind": "constraint", "version": "27", "reason": "stay on 27",
   "packages": ["sampleepoch"]},
  {"component": "sampleexact", "kind": "constraint", "version": "1.2+dfsg-1", "reason": "exactly this build",
   "packages": ["sampleplus"]},
  {"component": "sampleother", "kind": "constraint", "version": "9", "reason": "a series it never had",
   "packages": ["sampleother"]},
  {"component": "samplesemver", "kind": "constraint", "version": ">=16", "reason": "semver style",
   "packages": ["samplecli"]},
  {"component": "sampleline", "kind": "hold", "version": "2.0-1\n\nPackage: *", "reason": "x",
   "packages": ["sampleapp"]}
]}'
CLI='{"kept": [{"component": "sampledbms", "kind": "constraint", "version": "16", "reason": "the clusters run on 16",
   "packages": ["sampledbms-16", "samplecli", "sampledbms-lib"]}]}'
candidates() {
  local name
  for name in "$@"; do
    printf '%s %s\n' "$name" "$(APT_CONFIG=$WORLD/apt.conf apt-cache policy "$name" | awk '/Candidate:/ {print $2}')"
  done
}
upgraded_to() {
  jq -r --arg name "$1" '[.changes.upgrade[] | select(.name == $name) | .version] | first // "none"' "$PLAN"
}
owner_pins() {
  local codename
  codename=$(sed -n 's/^Codename: //p' "$WORLD"/repo/dists/*-updates/Release | head -n 1)
  printf 'Package: *\nPin: release a=%s-proposed\nPin-Priority: 100\n\nPackage: *\nPin: release a=%s-backports\nPin-Priority: 100\n\nPackage: *\nPin: release o=Example Vendor\nPin-Priority: -1\n' \
    "$codename" "$codename" >"$WORLD/etc/apt/preferences.d/00owner"
}
PACKAGES=(sampledbms-16 samplecli sampledbms-lib sampledbms-17 sampleapp sampleepoch sampleplus linux-firmware)

# --- the owner's apt: nothing is written, nothing changes ----------------------------------------
world_up constraints-safe
owner_pins
before=$(candidates "${PACKAGES[@]}")
APT_CONFIG=$WORLD/apt.conf DOTSTEWARD_APT_SUDO='' ds_python dotsteward_cli.apt_plan policy --request - \
  <<<"$KEPT" >"$DS_TEST_ROOT/out/policy.json" 2>"$DS_TEST_ROOT/policy.err" || ds_fail "policy: $(<"$DS_TEST_ROOT/policy.err")"
[[ ! -e $WORLD/etc/apt/preferences.d/61dotsteward-kept ]] || ds_fail "a preferences file for the constraints"
assert_eq "$before" "$(candidates "${PACKAGES[@]}")" "the owner's apt sees what it saw before"
assert_contains "$(APT_CONFIG=$WORLD/apt.conf apt-get -s install samplecli=17.2-1 2>&1)" "Inst samplecli [16.15-1] (17.2-1"

# --- the plan of dotsteward keeps to the rules ----------------------------------------------------
world_plan constraints-safe "$KEPT"
assert_eq 16.16-1 "$(upgraded_to sampledbms-16)" "no prerelease of -proposed, no version of an origin turned off"
assert_eq 16.16-1 "$(upgraded_to samplecli)" "the newest inside the constraint"
assert_eq 17.2-1 "$(upgraded_to sampledbms-lib)" "a shared library is not bound"
assert_eq 17.12-1 "$(upgraded_to sampledbms-17)" "the owner's other major still upgrades"
assert_eq 1.5-1 "$(upgraded_to sampleapp)" "a hold keeps what is below it"
assert_eq 5:27.3.2-1 "$(upgraded_to sampleepoch)" "an epoch is inside its series"
assert_eq none "$(upgraded_to sampleplus)" "an exact version is that version alone"
assert_eq 20240318.git3b128b60-0ubuntu2.27 "$(upgraded_to linux-firmware)" "firmware is never bound"
plan_item constraint-waits 'and .package == "samplecli" and .newest == "17.2-1" and .pending == false'
plan_item constraint-waits 'and .package == "sampleepoch" and .newest == "5:28.0.0-1"'
plan_item constraint-shared 'and .package == "sampledbms-lib" and .needed_by == "sampledbms-17"'
plan_item constraint-matches-nothing 'and .component == "sampleother"'
plan_item constraint-invalid 'and .component == "samplesemver"'
plan_item constraint-invalid 'and .component == "sampleline"'
plan_no_item kept-back

world_analysis constraints-safe "$KEPT"
assert_json "$ANALYSIS" '.kept[] | select(.name == "samplecli") | .candidate == "16.16-1" and .free == "17.2-1" and .why == "constraint" and .component == "sampledbms"'
assert_json "$ANALYSIS" '.kept[] | select(.name == "sampleapp") | .candidate == "1.5-1" and .free == "2.0-1" and .why == "hold"'

# --- only an untrusted origin has a version inside: the package stays, the newer one waits -------
world_up constraints-proposed
owner_pins
world_plan constraints-proposed "$CLI"
assert_eq none "$(upgraded_to samplecli)"
plan_item constraint-waits 'and .package == "samplecli" and .newest == "17.2-1"'

# --- the owner took it out of its constraint: it stays theirs -----------------------------------
world_plan constraints-handmoved "$CLI"
assert_eq none "$(upgraded_to samplecli)"
plan_item constraint-left-by-owner 'and .package == "samplecli" and .installed == "17.2-1" and .pending == false'
world_up constraints-handmoved
assert_contains "$(APT_CONFIG=$WORLD/apt.conf apt-get -s upgrade 2>&1)" "Inst samplecli [17.2-1] (17.2-2"

# --- a library tied through a versioned Provides or a Breaks is not bound ------------------------
world_plan constraints-provides "$CLI"
plan_item constraint-shared 'and .package == "sampledbms-lib" and .needed_by == "sampledbms-17"'
world_plan constraints-breaks "$CLI"
plan_item constraint-shared 'and .package == "sampledbms-lib" and .needed_by == "sampledbms-17"'
assert_eq 17.12-1 "$(upgraded_to sampledbms-17)"
plan_no_item kept-back

# --- the check of E2E has nothing of the constraints to say -------------------------------------
check=$(APT_CONFIG=$WORLD/apt.conf ds_python dotsteward_cli.apt_plan check-files --request - <<<"$KEPT" 2>&1) ||
  ds_fail "check-files failed: $check"
assert_not_contains "$check" "kept"
