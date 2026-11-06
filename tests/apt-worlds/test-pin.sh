# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The pin of the plan binds apt: under it the candidate of every installed package of a
# gated class is the installed version, on every architecture, with new versions in the
# archive. A `src:` pin without `:any` holds only the native architecture: the i386
# libraries of the driver would slip through.
# shellcheck source=tests/apt-worlds/helpers.sh
source "$DS_REPO_ROOT/tests/apt-worlds/helpers.sh"
world_require

candidates_are_installed() {
  local names name policy
  names=$(jq -r '.gated.installed_pairs | length' "$PLAN")
  ((names > 0)) || ds_fail "the plan names no installed pair"
  for name in linux-generic-hwe-24.04 linux-image-generic-hwe-24.04 linux-modules-nvidia-595-open-generic-hwe-24.04 \
    linux-modules-nvidia-595-open-7.0.0-42-generic linux-modules-nvidia-595-open-7.0.0-38-generic \
    nvidia-driver-595-open nvidia-kernel-common-595 libnvidia-gl-595 libnvidia-gl-595:i386 libnvidia-compute-595:i386; do
    policy=$(APT_CONFIG=$WORLD/apt.conf apt-cache policy "$name")
    installed=$(awk '/Installed:/ {print $2}' <<<"$policy")
    candidate=$(awk '/Candidate:/ {print $2}' <<<"$policy")
    assert_eq "$installed" "$candidate" "the candidate of $name under the pin"
  done
}

for name in same-string plus-n driver-respin kernel-and-driver packaging-bump transitional new-series new-series-nvidia; do
  world_plan "$name"
  jq -r .gated.pin "$PLAN" >"$WORLD/etc/apt/preferences.d/60dotsteward"
  candidates_are_installed
  simulation=$(APT_CONFIG=$WORLD/apt.conf apt-get -s full-upgrade 2>&1)
  assert_not_contains "$simulation" "Inst linux-"
  assert_not_contains "$simulation" "Inst nvidia-"
  assert_not_contains "$simulation" "Inst libnvidia-"
  assert_not_contains "$simulation" "Remv "
  rm -f "$WORLD/etc/apt/preferences.d/60dotsteward"
done

# The file describes what dpkg has: one (source, version) per record, both fallback
# and current ABI, priority 990, and never the target.
world_plan driver-respin
pin=$(jq -r .gated.pin "$PLAN")
assert_contains "$pin" "Package: src:linux-meta-hwe-7.0:any
Pin: version $K42
Pin-Priority: 990"
assert_contains "$pin" "Package: src:linux-restricted-signatures-hwe-7.0:any
Pin: version $K38+1
Pin-Priority: 990"
assert_contains "$pin" "Package: src:linux-restricted-signatures-hwe-7.0:any
Pin: version $K42
Pin-Priority: 990"
assert_contains "$pin" "Package: src:nvidia-graphics-drivers-595:any
Pin: version $D99
Pin-Priority: 990"
assert_contains "$pin" "Package: src:linux-meta*:any src:linux-restricted-modules*:any src:linux-restricted-signatures*:any src:nvidia-graphics-drivers-*:any
Pin: version *
Pin-Priority: -1"
assert_not_contains "$pin" "$D106"

# A new kernel flavour of a meta package the machine does not have gets no candidate
# either, and neither does a series that is not installed.
world_plan new-series-nvidia
jq -r .gated.pin "$PLAN" >"$WORLD/etc/apt/preferences.d/60dotsteward"
policy=$(APT_CONFIG=$WORLD/apt.conf apt-cache policy nvidia-driver-615-open)
assert_contains "$policy" "Candidate: (none)"
policy=$(APT_CONFIG=$WORLD/apt.conf apt-cache policy libnvidia-gl-615:i386)
assert_contains "$policy" "Candidate: (none)"
rm -f "$WORLD/etc/apt/preferences.d/60dotsteward"

# The real file of ours plays no part in a plan: a stale or wrong one changes nothing,
# because the plan builds its own from dpkg. The files of others stay in force.
world_plan same-string
assert_json "$PLAN" '.gated.decision == "move"'
printf 'Package: src:linux-meta*:any\nPin: version *\nPin-Priority: -1\n' >"$WORLD/etc/apt/preferences.d/60dotsteward"
world_plan same-string
assert_json "$PLAN" '.gated.decision == "move"'
plan_target "$K44" "$K44" "$D99"
rm -f "$WORLD/etc/apt/preferences.d/60dotsteward"
world_up tracked
printf 'Package: example-tracked\nPin: version *\nPin-Priority: -1\n' >"$WORLD/etc/apt/preferences.d/example.pref"
world_plan tracked
assert_json "$PLAN" '[.changes.upgrade[].name] | index("example-tracked") == null'
rm -f "$WORLD/etc/apt/preferences.d/example.pref"
