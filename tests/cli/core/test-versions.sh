# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The one version order: the internal command, the methods library of hooks
# and the pins engine answer the same for every pair; 1.2.3-rc1 sorts before
# 1.2.3 everywhere. It is the algorithm of dpkg behind a small pre-pass, so it is
# a real order and agrees with dpkg on package versions. Stage 0 is the one
# exception: it runs before there is any Python and compares only dotted
# operating system versions.
# shellcheck source=tests/cli/core/helpers.sh
source "$DS_REPO_ROOT/tests/cli/core/helpers.sh"

# The order, as "LEFT RIGHT EXPECTED". A release sorts after its pre-releases
# (after ~, after - and a letter, or attached like rc1 and .dev0) and before its
# package revisions (after - and a digit) and what follows + (as esm1 in an
# index, build5 in a release); parts compare as numbers and words, numbers first;
# a missing part sorts first; a leading v and an epoch are understood.
pairs=(
  "1.2.3 1.2.3 0"
  "1.2.3 1.2.4 -1"
  "1.10.0 1.9.0 1"
  "1.2 1.2.0 -1"
  "v1.2.3 1.2.3 0"
  "1.2.3-rc1 1.2.3 -1"
  "1.2.3~rc1 1.2.3 -1"
  "1.2.3-rc1 1.2.2 1"
  "1.2.3-rc.1 1.2.3-rc.2 -1"
  "1.2.3-rc.2 1.2.3-rc.10 -1"
  "1.2.3-rc9 1.2.3-rc10 -1"
  "1.0.0-alpha 1.0.0-alpha.1 -1"
  "1.0.0-alpha.1 1.0.0-alpha.beta -1"
  "1.0.0-alpha.beta 1.0.0-beta -1"
  "1.0.0-beta.2 1.0.0-beta.11 -1"
  "1.0.0-beta.11 1.0.0-rc.1 -1"
  "1.0.0-rc.1 1.0.0 -1"
  "1.2.3rc1 1.2.3 -1"
  "2.0.0a1 2.0.0b1 -1"
  "2.0.0b2 2.0.0rc1 -1"
  "1.2.3rc1 1.2.3-rc1 0"
  "1.2.3RC1 1.2.3rc1 0"
  "1.2.3.dev0 1.2.3 -1"
  "7.1.0.beta1 7.1.0 -1"
  "7.1.0.beta1 7.1.0.beta2 -1"
  "1.2.3.rc1 1.2.3 -1"
  "2.0.0b1-3 2.0.0-1 -1"
  "1.2.3 1.2.3+build5 -1"
  "1.2.3+build5 1.2.3+build6 -1"
  "1.2.3+1 1.2.3+2 -1"
  "1.2-1 1.2-1+esm1 -1"
  "1.2.3-1~example+1 1.2.3-1 -1"
  "2.3-0example8cross1 2.3-0example8.2cross1 -1"
  "2.3-0example8.2cross1 2.3-0example9 -1"
  "1.2.3-1 1.2.3 1"
  "1.2.3-1 1.2.4 -1"
  "1.2.3-2 1.2.3-10 -1"
  "1.2.3-1ubuntu2 1.2.3-1ubuntu10 -1"
  "1.2.3-1~example24.04 1.2.3-2~example24.04 -1"
  "1:1.0-1 2.0-1 1"
  "2:1.0-1 1:9.0-1 1"
  "1.2+dfsg-1 1.2+dfsg-2 -1"
  "1.2.10a 1.2.11 -1"
  "1.2.3 1.2.3a -1"
  "example-25.11 example-26.05 -1"
  "example-unstable example-26.05 -1"
  "latest 0.0.1 -1"
)

# Every pair, in both directions, through the internal command.
for pair in "${pairs[@]}"; do
  read -r left right expected <<<"$pair"
  assert_eq "$expected" "$(internal version-compare -- "$left" "$right")" "version-compare $pair"
  assert_eq "$((-expected))" "$(internal version-compare -- "$right" "$left")" "version-compare, reversed, $pair"
done

assert_exit 2 internal version-compare 1.2.3
assert_contains "$DS_STDERR" "usage:"
# Digits are ASCII digits; anything else is a word, never a crash.
assert_eq 1 "$(internal version-compare "$(printf '1.\331\243a')" 1.2)" "another script's digit"
assert_eq 0 "$(internal version-compare "" "")" "two empty versions"
assert_eq -1 "$(internal version-compare -- -rc1 1.0)" "a version that looks like an option"
long=$(printf '9%.0s' {1..5000})
assert_eq 1 "$(internal version-compare "1.$long" 1.2)" "a number too long for an integer"

# --- real-looking versions, and that this is an order --------------------------------

# Pairs in the shapes of real package indexes, with the answer of dpkg. Where
# dpkg is at hand, it gives the answers again, so the file cannot drift.
sample=$DS_REPO_ROOT/tests/cli/core/fixtures/version-pairs.txt
core_python - "$sample" "${pairs[@]}" <<'PY' || ds_fail "the order disagrees with dpkg or is no order"
import random
import sys

from dotsteward_cli import versions

failures = []
known = set()
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        if line.startswith("#"):
            continue
        left, right, expected = line.split()
        known.update((left, right))
        if versions.compare(left, right) != int(expected):
            failures.append(f"compare {left} {right}: {versions.compare(left, right)}, dpkg says {expected}")
        if versions.compare(right, left) != -int(expected):
            failures.append(f"compare, reversed, {left} {right}")
if len(known) < 300:
    failures.append(f"the sample has only {len(known)} versions")
for pair in sys.argv[2:]:
    known.update(pair.split()[:2])

# Antisymmetric and transitive, on the sample and the table together.
versions_list = sorted(known)
rng = random.Random(20261107)
for _ in range(30000):
    a, b, c = rng.choice(versions_list), rng.choice(versions_list), rng.choice(versions_list)
    ab, bc, ac = versions.compare(a, b), versions.compare(b, c), versions.compare(a, c)
    if ab <= 0 and bc <= 0 and ac > 0:
        failures.append(f"not transitive: {a} <= {b} <= {c}, but {a} > {c}")
    if ab >= 0 and bc >= 0 and ac < 0:
        failures.append(f"not transitive: {a} >= {b} >= {c}, but {a} < {c}")
    if versions.compare(b, a) != -ab:
        failures.append(f"not antisymmetric: {a} {b}")

# The three that were no order: with build metadata ignored only against a
# version without any, 1.2.3 equalled both others, which differ.
trio = ["1.2.3+2", "1.2.3", "1.2.3+1"]
for order in (trio, list(reversed(trio)), sorted(trio)):
    if sorted(order, key=versions.sort_key) != ["1.2.3", "1.2.3+1", "1.2.3+2"]:
        failures.append(f"sorted {order}: {sorted(order, key=versions.sort_key)}")
for order in (["1.2.3", "1.2.3+1"], ["1.2.3+1", "1.2.3"]):
    if versions.newest(order) != "1.2.3+1":
        failures.append(f"newest {order}: {versions.newest(order)}")
print("\n".join(failures[:20]), file=sys.stderr)
sys.exit(1 if failures else 0)
PY
if command -v dpkg >/dev/null 2>&1; then
  answers=(lt eq gt)
  while read -r left right expected; do
    [[ $left != '#' ]] || continue
    dpkg --compare-versions "$left" "${answers[expected + 1]}" "$right" ||
      ds_fail "dpkg does not say $left ${answers[expected + 1]} $right: the sample is wrong"
  done <"$sample"
fi

# --- the bash library of hooks ---------------------------------------------------

methods_shell() {
  bash --noprofile --norc -c '
    source "$DOTSTEWARD_LIB/lib.sh"
    source "$DOTSTEWARD_LIB/config.sh"
    source "$DOTSTEWARD_LIB/methods.sh"
    "$@"
  ' bash "$@"
}
export DOTSTEWARD_LIB=$DS_REPO_ROOT/cli/lib
for pair in "${pairs[@]}"; do
  read -r left right expected <<<"$pair"
  assert_eq "$expected" "$(methods_shell methods_version_compare "$left" "$right")" "methods_version_compare $pair"
done
assert_exit 0 methods_shell methods_version_at_least 1.2.3 1.2.3
assert_exit 0 methods_shell methods_version_at_least 1.2.3 1.2.3-rc1
assert_exit 1 methods_shell methods_version_at_least 1.2.3-rc1 1.2.3
assert_exit 1 methods_shell methods_version_at_least "" 1.2.3
assert_eq -1 "$(methods_shell methods_version_compare -rc1 1.0)" "methods_version_compare with a version that looks like an option"

# A broken interpreter is an error, never a version that passes the floor.
mkdir -p "$DS_TEST_ROOT/broken-bin"
printf '#!/bin/sh\nexit 7\n' >"$DS_TEST_ROOT/broken-bin/python3"
chmod +x "$DS_TEST_ROOT/broken-bin/python3"
broken_shell() {
  PATH=$DS_TEST_ROOT/broken-bin:$PATH methods_shell "$@"
}
assert_exit 1 broken_shell methods_version_at_least 1.2.4 1.2.3
# Two equal strings need no interpreter: the usual check costs no process.
assert_eq 0 "$(broken_shell methods_version_compare 1.2.3 1.2.3)" "equal strings"
assert_exit 0 broken_shell methods_version_at_least 1.2.3 1.2.3

# --- the pins engine -------------------------------------------------------------

core_python - "$DS_REPO_ROOT" "${pairs[@]}" <<'PY' || ds_fail "the pins engine orders versions differently"
import sys

sys.path.insert(0, f"{sys.argv[1]}/engines/pins")

from dotsteward_pins.latest.model import classify

from dotsteward_cli import versions

failures = []
for pair in sys.argv[2:]:
    left, right, expected = pair.split()
    if versions.compare(left, right) != int(expected):
        failures.append(f"compare {pair}")
    if int(expected) < 0 and versions.newest([right, left]) != right:
        failures.append(f"newest {pair}")
    if int(expected) > 0 and versions.newest([right, left]) != left:
        failures.append(f"newest {pair}")
for current, latest, status in (
    ("1.2.3-rc1", "1.2.3", "update"),
    ("1.2.3", "1.2.3-rc1", "current"),
    ("1.2.3", "1.2.3", "current"),
    ("1.2.3", "1.2.4", "update"),
    ("1.2.3", "2.0.0", "review"),
    ("0.2.3", "0.3.0", "review"),
    ("0.2.3", "0.2.4", "update"),
    ("1.2.3-1", "1.2.3-2", "update"),
    ("1.2-1", "1.2-1+esm1", "update"),
    ("1.2.3-1~example+1", "1.2.3-1", "update"),
):
    if classify(current, latest) != status:
        failures.append(f"classify {current} {latest}: {classify(current, latest)}, expected {status}")
print("\n".join(failures), file=sys.stderr)
sys.exit(1 if failures else 0)
PY

# --- stage 0 ----------------------------------------------------------------------

# The one copy that cannot call Python: it compares operating system versions
# before Nix exists, and there a missing part is 0.
stage0=$(sed -n '/^preflight_version_at_least() {$/,/^}$/p' "$DS_REPO_ROOT/cli/commands/preflight.sh")
[[ -n $stage0 ]] || ds_fail "cannot read preflight_version_at_least"
eval "$stage0"
for pair in "24.04 24.04" "26.04 24.04" "24.10 24.04" "14.7.1 14.7" "15.0 14.7.1"; do
  read -r version minimum <<<"$pair"
  preflight_version_at_least "$version" "$minimum" || ds_fail "stage 0: $version is at least $minimum"
  [[ $(internal version-compare "$version" "$minimum") != -1 ]] || ds_fail "the order: $version is at least $minimum"
done
for pair in "22.04 24.04" "24.04 24.10" "14.7 14.7.1" "13.7 14.0"; do
  read -r version minimum <<<"$pair"
  ! preflight_version_at_least "$version" "$minimum" || ds_fail "stage 0: $version is below $minimum"
  assert_eq -1 "$(internal version-compare "$version" "$minimum")" "the order: $version is below $minimum"
done
preflight_version_at_least 14 14.0 || ds_fail "stage 0: a missing part is 0"

# --- one implementation ------------------------------------------------------------

# Nothing else in the package parses versions.
others=$(grep -rnE 'def version_key|findall\(r"\\d\+"' "$DS_REPO_ROOT/cli/python" "$DS_REPO_ROOT/engines" --include='*.py' |
  grep -v 'cli/python/dotsteward_cli/versions.py' || true)
assert_eq "" "$others" "another version parser"
