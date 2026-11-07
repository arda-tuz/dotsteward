# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Default allow, with a refusal list for named risk classes. A refusal holds the
# whole plan back, the run waits for a person (exit 3) and review.json says what to do.
# shellcheck source=tests/apt-worlds/helpers.sh
source "$DS_REPO_ROOT/tests/apt-worlds/helpers.sh"
world_require

CONSTRAINED='{"constraints": {"sampledbms": "16"}}'

# A constrained server: a floating meta package reaches for another major version.
world_report constrained-major "$CONSTRAINED"
assert_eq 3 "$WORLD_STATUS" "a refusal waits for a person"
plan_refused
plan_item apt-denied 'and .class == "constrained-major" and .packages == ["sampledbms-19"] and .pending == true'
plan_item apt-denied 'and .pulled_by == "sampledbms-19-postgis-3-scripts"'
assert_json "$REVIEW" '[.items[] | select(.code == "apt-denied")] | length == 1'
assert_json "$REVIEW" '.items[] | select(.code == "apt-denied") | .class == "constrained-major" and .packages == ["sampledbms-19"]'
assert_json "$REVIEW" '.items[] | select(.code == "apt-denied") | .accept == "dotsteward upgrade --accept install:sampledbms-19"'
assert_json "$REVIEW" '.exit_code == 3 and .status == "pending"'

# The upgrades of majors that are installed are no new install of a major: not refused.
plan_changes upgrade sampledbms-16 sampledbms-17

# With the constraint out of the way the same plan passes.
world_report constrained-major '{}'
assert_eq 0 "$WORLD_STATUS"
plan_applicable
plan_changes install sampledbms-19

# --accept names the package: the plan goes on, the run has nothing left to ask.
world_report constrained-major '{"constraints": {"sampledbms": "16"}, "accept": ["install:sampledbms-19"]}'
assert_eq 0 "$WORLD_STATUS"
plan_applicable
plan_no_item apt-denied
[[ ! -e $REVIEW ]] || ds_fail "a run without items leaves no review.json"

# The target kernel brings another flavour.
world_plan new-flavour
plan_refused
plan_item apt-denied 'and .class == "kernel-flavour" and .packages == ["linux-image-7.0.0-44-lowlatency"]'
world_plan new-flavour '{"accept": ["install:linux-image-7.0.0-44-lowlatency", "install:linux-modules-7.0.0-44-lowlatency"]}'
plan_applicable

# Stable meta package, kernel only in -proposed: an origin that is not allowed, in a gated class.
world_plan proposed-abi
plan_refused
plan_item apt-denied 'and .class == "origin" and .packages == ["linux-image-7.0.0-44-generic"]'
assert_json "$PLAN" '[.items[] | select(.code == "apt-denied") | .accept] | all(. == null)'

# The module accepts the driver but does not provide its DKMS dependency: apt reaches for DKMS.
world_plan dkms-pull
plan_refused
plan_item apt-denied 'and .class == "dkms" and .packages == ["nvidia-dkms-595-open"]'

# Removal is refused by default: a package of another Source has no rule.
world_report foreign-removal '{}'
assert_eq 3 "$WORLD_STATUS"
plan_refused
plan_item apt-denied 'and .class == "removal" and .packages == ["example-other"]'
assert_json "$PLAN" '[.items[] | select(.code == "apt-denied") | .accept] | all(. == null)'

# A package of an old ABI goes; the same package goes nowhere when that ABI is running.
world_plan old-abi-conflict
plan_applicable
assert_json "$PLAN" '.changes.remove == [{"name": "linux-tools-7.0.0-38-generic", "reason": "old-abi", "source": "linux-hwe-7.0", "version": "7.0.0-38.38~24.04.4"}]'
world_plan old-abi-conflict '{"running_kernel": "7.0.0-38-generic"}'
plan_refused
plan_item apt-denied 'and .class == "removal" and .packages == ["linux-tools-7.0.0-38-generic"]'

# A removal in a gated class that the shared target did not announce is refused: the fallback
# keeps its module as long as the driver suits it. Only `losses` lets a module go.
world_plan module-conflict
plan_refused
plan_item apt-denied 'and .class == "removal" and .packages == ["linux-modules-nvidia-595-open-7.0.0-38-generic"]'
assert_json "$PLAN" '.gated.target.losses == []'

# `[apt.gated] enable = false`: no pin and no shared target, so apt may reach for what the
# classes hold back; the list still stops another series, a kernel without module, DKMS.
world_plan no-module '{"gated": false}'
plan_refused
assert_json "$PLAN" '.gated.decision == "off" and .gated.target == null'
plan_item apt-denied 'and .class == "module-missing" and .packages == ["linux-image-7.0.0-44-generic"]'
world_plan driver-ahead '{"gated": false}'
plan_refused
plan_item apt-denied 'and .class == "dkms" and .packages == ["nvidia-dkms-595-open"]'
# A driver move inside the series: a plain full upgrade wants to remove every NVIDIA module,
# because each module package fixes the upstream version of the driver. No rule allows that.
for module in generic-hwe-24.04 7.0.0-42-generic 7.0.0-38-generic; do
  plan_item apt-denied "and .class == \"removal\" and .packages == [\"linux-modules-nvidia-595-open-$module\"]"
done
world_plan other-series-pull '{"gated": false, "accept": []}'
plan_refused
plan_item apt-denied 'and .class == "removal" and .packages == ["nvidia-driver-595-open"]'
world_plan other-series-new '{"gated": false}'
plan_refused
plan_item apt-denied 'and .class == "driver-series" and .packages == ["nvidia-driver-700-open"] and .pulled_by == "example-tracked"'
assert_json "$PLAN" '[.items[] | select(.code == "apt-denied") | .accept] | all(. == null)'
world_plan proposed-and-ppa '{"gated": false}'
plan_refused
assert_json "$PLAN" '[.items[] | select(.code == "apt-denied" and .class == "origin")] | length > 0'

# Under the gate the same worlds hold the classes back without a refusal.
for name in other-series-pull other-series-new; do
  world_plan "$name"
  plan_applicable
  plan_unchanged
  plan_item kept-back 'and .packages == ["example-tracked"]'
done

# A hold is apt's own: nothing to refuse, and the report names it.
world_plan held-package
plan_applicable
plan_changes upgrade example-other
plan_no_change upgrade example-tracked
plan_item kept-back 'and .packages == ["example-tracked"]'
