# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2034 # the versions are read by the test files that source this
# Helpers for the apt worlds (not a test file): a real apt and a real python3-apt on
# synthetic records, rootless, with a status file and lists of its own. The helper runs
# under /usr/bin/python3, so these tests cannot run in the build sandbox.
#
#   world_require           ends the test with a SKIP line without python3-apt
#   world_modinfo [SIGNER [MISSING [VERSION]]]
#                           the modinfo of the engine: it finds the module of every kernel with
#                           SIGNER (default the distribution's) and VERSION (default it says
#                           none), except the releases in MISSING; `all`: of none
#   world_up NAME           builds world NAME once and fetches its lists; WORLD is its root
#   world_plan NAME [JSON]  the plan of NAME for the request {mode: "all",
#                           running_kernel: "7.0.0-42-generic"} + JSON; PLAN is its file
#   world_report NAME JSON  the same through --report apt-test: WORLD_STATUS is the exit
#                           code, REVIEW the review file
#   world_analysis NAME JSON
#                           the read only analysis; ANALYSIS is its file
#   plan_item CODE [FILTER] exactly one item with CODE (and the jq FILTER, "and ...")
#   plan_no_item CODE       no item with CODE
#   plan_changes BUCKET NAME...
#                           each NAME is in .changes.BUCKET
#   plan_unchanged          the plan changes nothing
#   plan_target K M D       the target of the gated classes

# shellcheck source=cli/lib/python.sh
source "$DS_REPO_ROOT/cli/lib/python.sh"

WORLDS_PY=$DS_REPO_ROOT/tests/apt-worlds/fixtures/worlds.py
K38="7.0.0-38.38~24.04.4"
K42="7.0.0-42.42~24.04.1"
K44="7.0.0-44.44~24.04.1"
K46="7.0.0-46.46~24.04.1"
K74="7.4.0-5.5~24.04.1"
D99="595.99.02-0ubuntu0.24.04.1"
D99B="595.99.02-0ubuntu0.24.04.2"
D106="595.106.01-0ubuntu0.24.04.1"
D615="615.71.09-0ubuntu0.24.04.2"

world_require() {
  if ! /usr/bin/python3 -I -c 'import apt, apt_pkg' 2>/dev/null || ! type -P apt-get >/dev/null; then
    printf 'SKIP: the apt worlds need /usr/bin/python3 with python3-apt and apt-get\n'
    exit 0
  fi
  mkdir -p "$DS_TEST_ROOT/world-bin" "$DS_TEST_ROOT/worlds" "$DS_TEST_ROOT/out"
  export PATH=$DS_TEST_ROOT/world-bin:$PATH
  # apt includes every phased update when SOURCE_DATE_EPOCH is set (a reproducible build), and the
  # dev shell (nix develop) sets it; a machine does not, so the worlds phase as a machine does.
  unset SOURCE_DATE_EPOCH
  # The host's own tool looks at the host's hardware; a test that wants it writes its answers.
  world_ubuntu_drivers ''
  world_modinfo
}

world_modinfo() {
  mkdir -p "$DS_TEST_ROOT/world-bin"
  export DOTSTEWARD_MODINFO=$DS_TEST_ROOT/world-bin/modinfo-stub
  cat >"$DOTSTEWARD_MODINFO" <<SCRIPT
#!/bin/sh
# Called as: modinfo -k RELEASE -F FIELD nvidia
case " ${2:-} " in *" all "*|*" \$2 "*) exit 1 ;; esac
case "\$4" in
  signer) echo "${1:-Canonical Ltd. Kernel Module Signing}" ;;
  version) [ -z "${3:-}" ] || echo "${3:-}" ;;
esac
SCRIPT
  chmod +x "$DOTSTEWARD_MODINFO"
}

# world_ubuntu_drivers TEXT: what `ubuntu-drivers devices` prints on standard output,
# next to the noise of the real tool on standard error; empty: it fails.
world_ubuntu_drivers() {
  printf '%s\n' "${1:-}" >"$DS_TEST_ROOT/out/ubuntu-drivers.devices"
  printf '%s\n%s\n%s\n%s\n' '#!/bin/sh' 'echo "devtool hwdb is deprecated. Use systemd-hwdb instead." >&2' \
    "[ \"\$(wc -c <\"$DS_TEST_ROOT/out/ubuntu-drivers.devices\")\" -gt 1 ] || exit 1" \
    "cat \"$DS_TEST_ROOT/out/ubuntu-drivers.devices\"" >"$DS_TEST_ROOT/world-bin/ubuntu-drivers"
  chmod +x "$DS_TEST_ROOT/world-bin/ubuntu-drivers"
}

world_up() {
  WORLD=$DS_TEST_ROOT/worlds/$1
  [[ ! -f $WORLD/apt.conf ]] || return 0
  /usr/bin/python3 -I "$WORLDS_PY" build "$1" "$WORLD"
  APT_CONFIG=$WORLD/apt.conf apt-get update -qq >"$WORLD/update.log" 2>&1 ||
    ds_fail "apt-get update failed in world $1: $(<"$WORLD/update.log")"
  if [[ -s $WORLD/update.log ]]; then
    ds_fail "apt-get update has something to say in world $1: $(<"$WORLD/update.log")"
  fi
}

world_request() {
  jq -cn --argjson extra "${1:-{\}}" '{mode: "all", running_kernel: "7.0.0-42-generic"} + $extra'
}

world_plan() {
  world_up "$1"
  PLAN=$DS_TEST_ROOT/out/$1.plan.json
  APT_CONFIG=$WORLD/apt.conf ds_python dotsteward_cli.apt_plan plan --request - \
    <<<"$(world_request "${2:-{\}}")" >"$PLAN" 2>"$PLAN.err" ||
    ds_fail "the plan of world $1 failed: $(<"$PLAN.err")"
}

world_report() {
  world_up "$1"
  PLAN=$DS_TEST_ROOT/out/$1.report.json
  REVIEW=$DOTSTEWARD_STATE_ROOT/review.json
  WORLD_STATUS=0
  APT_CONFIG=$WORLD/apt.conf ds_python dotsteward_cli.apt_plan plan --request - --report apt-test \
    <<<"$(world_request "${2:-{\}}")" >"$PLAN" 2>"$PLAN.err" || WORLD_STATUS=$?
}

world_analysis() {
  world_up "$1"
  ANALYSIS=$DS_TEST_ROOT/out/$1.analysis.json
  APT_CONFIG=$WORLD/apt.conf ds_python dotsteward_cli.apt_plan analysis --request - \
    <<<"$(world_request "${2:-{\}}")" >"$ANALYSIS" 2>"$ANALYSIS.err" ||
    ds_fail "the analysis of world $1 failed: $(<"$ANALYSIS.err")"
}

plan_item() {
  assert_json "$PLAN" "[.items[] | select(.code == \"$1\" ${2:-})] | length == 1" "item $1 ${2:-}"
}

plan_no_item() {
  assert_json "$PLAN" "[.items[] | select(.code == \"$1\")] | length == 0" "no item $1"
}

plan_changes() {
  local bucket=$1 name
  shift
  for name in "$@"; do
    assert_json "$PLAN" "[.changes.${bucket}[].name] | index(\"$name\") != null" "$name in $bucket"
  done
}

plan_no_change() {
  local bucket=$1 name
  shift
  for name in "$@"; do
    assert_json "$PLAN" "[.changes.${bucket}[].name] | index(\"$name\") == null" "$name not in $bucket"
  done
}

plan_unchanged() {
  assert_json "$PLAN" '[.changes[][]] | length == 0' "the plan changes nothing"
}

plan_target() {
  assert_json "$PLAN" ".gated.target.kernel == \"$1\" and .gated.target.module == \"$2\" and .gated.target.driver == \"$3\"" \
    "the target is kernel $1, module $2, driver $3"
}

plan_applicable() {
  assert_json "$PLAN" '.applicable == true' "the plan is applicable"
}

plan_refused() {
  assert_json "$PLAN" '.applicable == false' "the plan is refused"
}
