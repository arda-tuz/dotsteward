# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # the header names a command in backquotes on purpose
# The version constraints and holds of the instance bind apt: `policy` writes them to a file of
# their own, 61dotsteward-kept: one record per package and rule that lowers what is outside the rule
# to -1 (tests/apt-worlds/test-constraints-safe.sh: never raises), so a version the owner asks for by
# name still installs. A constraint record goes to a package of the component whose versions are of
# its series; a package whose versions are another scheme gets none, and one the owner moved out of
# its constraint gets none either and only a note. A hold keeps the line of the installed upstream
# version while it is below the held one; past it (the owner moved it) there is no record and a note. A
# package of no component, such as another major the owner installed, is never pinned, and a gated
# class is left to the series rule. Plan, commit and analysis read the records the request gives,
# never a file left by an older run; the analysis says what they keep and why. The check of E2E only
# notes a file that is missing or differs.
# shellcheck source=tests/apt-worlds/helpers.sh
source "$DS_REPO_ROOT/tests/apt-worlds/helpers.sh"
world_require

KEPT='{"kept": [
  {"component": "sampledbms", "kind": "constraint", "version": "16.*", "reason": "the clusters run on 16",
   "packages": ["sampledbms-16", "sampledbms-client", "sampledbms-lib", "sampledbms-16-ext-3", "sampledbms-16-missing", "linux-generic-hwe-24.04"]},
  {"component": "sampletool", "kind": "constraint", "version": "1", "reason": "the old plugin API",
   "packages": ["sampletool"]},
  {"component": "samplenew", "kind": "constraint", "version": "16", "reason": "the same major as the server",
   "packages": ["samplenew"]},
  {"component": "sampleapp", "kind": "hold", "version": "2.0-1", "reason": "E2E red: sampleapp:start",
   "packages": ["sampleapp"]},
  {"component": "sampleheld", "kind": "hold", "version": "1.0-1", "reason": "E2E red: sampleheld:start",
   "packages": ["sampleheld"]}
]}'
policy() {
  POLICY=$DS_TEST_ROOT/out/policy.json
  APT_CONFIG=$WORLD/apt.conf DOTSTEWARD_APT_SUDO='' ds_python dotsteward_cli.apt_plan policy --request - \
    <<<"$1" >"$POLICY" 2>"$DS_TEST_ROOT/policy.err" || ds_fail "policy failed: $(<"$DS_TEST_ROOT/policy.err")"
}
check() {
  CHECK=$(APT_CONFIG=$WORLD/apt.conf ds_python dotsteward_cli.apt_plan check-files --request - <<<"$1" 2>&1) ||
    ds_fail "check-files failed: $CHECK"
}
candidate() {
  APT_CONFIG=$WORLD/apt.conf apt-cache policy "$1" | awk '/Candidate:/ {print $2}'
}
upgraded_to() {
  jq -r --arg name "$1" '[.changes.upgrade[] | select(.name == $name) | .version] | first // "none"' "$PLAN"
}

header='# Managed by dotsteward: the version constraints and holds of the instance; change `version` in workstation.toml or a platform file, or the hold in hosts/<name>.toml. Only `dotsteward upgrade` writes it.'
# record NAME EXPLANATION: the record of NAME with its explanation, at -1.
record() {
  printf 'Explanation: %s\nPackage: %s:any\nPin: version /' "$2" "$1"
}
records() {
  local text=$1
  assert_contains "$text" "$header"
  assert_contains "$text" "$(record sampleapp 'sampleapp: a hold below 2.0-1, the line of 1.0 stays: E2E red: sampleapp:start')"
  assert_contains "$text" "$(record sampledbms-16 'sampledbms: version 16.*: the clusters run on 16')"
  assert_contains "$text" "$(record sampledbms-client 'sampledbms: version 16.*: the clusters run on 16')"
  assert_contains "$text" "$(record sampledbms-lib 'sampledbms: version 16.*: the clusters run on 16')"
  assert_contains "$text" "$(record samplenew 'samplenew: version 16: the same major as the server')"
  assert_eq 5 "$(grep -c '^Pin-Priority: -1$' <<<"$text")"
  assert_eq 5 "$(grep -c '^Package: ' <<<"$text")"
}

# --- what `files` says and `policy` writes ------------------------------------------------------
world_up constraints
kept=$WORLD/etc/apt/preferences.d/61dotsteward-kept
files=$DS_TEST_ROOT/out/files.json
APT_CONFIG=$WORLD/apt.conf ds_python dotsteward_cli.apt_plan files --request - <<<"$KEPT" >"$files" ||
  ds_fail "files failed"
assert_eq "$kept" "$(jq -r .kept.path "$files")"
records "$(jq -r .kept.text "$files")"
[[ ! -e $kept ]] || ds_fail "files wrote the file"

policy "$KEPT"
records "$(<"$kept")"
assert_eq "$(jq -r .kept.text "$files")" "$(<"$kept")"
assert_file_mode "$kept" 644
assert_json "$POLICY" '.kept.present == true and .kept.changed == true'
assert_json "$POLICY" '[.items[] | select(.code == "constraint-outside")] | length == 1'
assert_json "$POLICY" '.items[] | select(.code == "constraint-outside") | .package == "sampletool" and .installed == "2.4-1" and .version == "1" and .pending == false'
assert_json "$POLICY" '.items[] | select(.code == "hold-outside") | .package == "sampleheld" and .installed == "1.2-1" and .pending == false'
assert_not_contains "$(<"$kept")" "linux-"
assert_not_contains "$(<"$kept")" "sampledbms-17"
assert_not_contains "$(<"$kept")" "sampledbms-16-ext-3"
assert_not_contains "$(<"$kept")" "sampletool"
assert_not_contains "$(<"$kept")" "sampleheld"
assert_not_contains "$(<"$kept")" "Pin-Priority: 990"
# The gated classes have their own file; this one does not depend on them.
[[ ! -e $WORLD/etc/apt/preferences.d/60dotsteward ]] || [[ $(<"$WORLD/etc/apt/preferences.d/60dotsteward") != *sampledbms* ]] ||
  ds_fail "the records went into the pin file of the gated classes"
policy "$KEPT"
assert_json "$POLICY" '.kept.changed == false'

# --- apt keeps to them, the owner's own packages stay free ---------------------------------------
assert_eq 16.16-1 "$(candidate sampledbms-client)" "a constrained package stays in its series"
assert_eq 16.16-1 "$(candidate sampledbms-16)"
assert_eq 16.16-1 "$(candidate sampledbms-lib)"
assert_eq 16.16-1 "$(candidate sampledbms-lib:i386)" "a record binds every architecture of the package"
assert_eq 16.2-1 "$(candidate samplenew)" "a bare series is the series"
assert_eq 1.0-1 "$(candidate sampleapp)" "a held package stays as dpkg has it"
assert_eq 3.8.0-1 "$(candidate sampledbms-16-ext-3)" "a package of another scheme is not bound"
assert_eq 17.12-1 "$(candidate sampledbms-17)" "the owner's other major is never pinned"
assert_eq 2.5-1 "$(candidate sampletool)" "a package the owner moved out of its constraint is not pulled back"
assert_eq 1.5-1 "$(candidate sampleheld)" "a package the owner moved past its hold is not held"
simulation=$(APT_CONFIG=$WORLD/apt.conf apt-get -s install sampleapp=2.0-1 2>&1)
assert_contains "$simulation" "Inst sampleapp [1.0-1] (2.0-1" "a version asked by name still installs"

# --- plan, commit and analysis read the request, never the file there ----------------------------
printf '%s\n' "$header" >"$kept"
world_plan constraints "$KEPT"
assert_eq 16.16-1 "$(upgraded_to sampledbms-client)"
assert_eq none "$(upgraded_to sampleapp)"
assert_eq 17.12-1 "$(upgraded_to sampledbms-17)"
assert_eq 2.5-1 "$(upgraded_to sampletool)"
assert_eq 3.8.0-1 "$(upgraded_to sampledbms-16-ext-3)"
plan_no_change install sampledbms-client
assert_json "$PLAN" '.gated.decision == "no-move"'
world_plan constraints '{}'
assert_eq 17.2-1 "$(upgraded_to sampledbms-client)" "without the constraint the series is free"
assert_eq 2.0-1 "$(upgraded_to sampleapp)"

world_analysis constraints "$KEPT"
assert_json "$ANALYSIS" '[.kept[].name] == ["sampleapp", "sampledbms-client", "sampledbms-lib", "sampledbms-lib:i386"]'
assert_json "$ANALYSIS" '[.kept[] | select(.name | startswith("sampledbms-lib")) | .why] == ["constraint", "constraint"]'
assert_json "$ANALYSIS" '.kept[] | select(.name == "sampledbms-client") | .current == "16.15-1" and .candidate == "16.16-1" and .free == "17.2-1" and .why == "constraint" and .component == "sampledbms" and .version == "16.*" and .reason == "the clusters run on 16"'
assert_json "$ANALYSIS" '.kept[] | select(.name == "sampleapp") | .candidate == "1.0-1" and .free == "2.0-1" and .why == "hold" and .version == "2.0-1"'
assert_json "$ANALYSIS" '[.packages[].name] | index("sampleapp") == null'
assert_json "$ANALYSIS" '.packages[] | select(.name == "sampledbms-client") | .candidate == "16.16-1"'

# --- the check of E2E: the file there against what `policy` writes, notes only -------------------
policy "$KEPT"
check "$KEPT"
assert_eq "" "$CHECK" "a file as policy wrote it"
printf '%s\nPackage: sampleapp\nPin: version 0.9-1\nPin-Priority: 990\n' "$header" >"$kept"
check "$KEPT"
assert_contains "$CHECK" $'note\tapt-kept-differs\t'"$kept"
assert_not_contains "$CHECK" "finding"
rm -f -- "$kept"
check "$KEPT"
assert_contains "$CHECK" $'note\tapt-kept-missing\t'"$kept"
assert_not_contains "$CHECK" "finding"
check '{}'
assert_eq "" "$CHECK" "nothing kept, no file: nothing to say"

# --- nothing left to keep: policy takes the file away --------------------------------------------
policy "$KEPT"
[[ -e $kept ]] || ds_fail "policy did not write the file"
policy '{}'
[[ ! -e $kept ]] || ds_fail "the file stays without a constraint or a hold"
assert_json "$POLICY" '.kept.present == false and .kept.changed == true'
check "$KEPT"
assert_contains "$CHECK" "apt-kept-missing"
policy "$KEPT"
printf 'Package: something-else\nPin: version 1\nPin-Priority: 990\n' >"$kept"
check '{}'
assert_contains "$CHECK" $'note\tapt-kept-unwanted\t'"$kept"
