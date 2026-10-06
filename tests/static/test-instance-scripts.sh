# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# T3: the instance static scripts of [gate] static run after the framework
# contracts, in order, from the instance root, with DOTSTEWARD_INSTANCE_ROOT,
# DOTSTEWARD_SANDBOX and a sourceable helper (DOTSTEWARD_STATIC_HELPER, which
# defines fail); the first failure stops the run and its exit status and
# message propagate.
# shellcheck source=tests/static/helpers.sh
source "$DS_REPO_ROOT/tests/static/helpers.sh"

inst=$DS_TEST_ROOT/inst
make_instance "$inst"
mkdir -p "$inst/tests"
log=$DS_TEST_ROOT/scripts.log

cat >"$inst/tests/static.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$DOTSTEWARD_STATIC_HELPER"
printf 'first root=%s sandbox=%s pwd=%s\n' "$DOTSTEWARD_INSTANCE_ROOT" "$DOTSTEWARD_SANDBOX" "$PWD" >>"$SCRIPTS_LOG"
[[ -f $DOTSTEWARD_INSTANCE_ROOT/workstation.toml ]] || fail "no workstation.toml"
if [[ -e $DOTSTEWARD_INSTANCE_ROOT/fail-first ]]; then
  fail "private block failed"
fi
SH
cat >"$inst/tests/more.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'second\n' >>"$SCRIPTS_LOG"
if [[ -e $DOTSTEWARD_INSTANCE_ROOT/fail-second ]]; then
  printf 'custom failure\n' >&2
  exit 7
fi
SH
chmod 0755 "$inst/tests/static.sh" "$inst/tests/more.sh"
printf '\n[gate]\nstatic = ["tests/static.sh", "tests/more.sh"]\n' >>"$inst/workstation.toml"
commit_instance "$inst"
export SCRIPTS_LOG=$log

# Both scripts run in order after the contracts.
cd "$inst/scripts"
assert_exit 0 static
assert_eq "first root=$inst sandbox=0 pwd=$inst"$'\n'"second" "$(<"$log")"
assert_contains "$DS_STDOUT" "[dotsteward] static: instance script tests/static.sh passed"
assert_contains "$DS_STDOUT" "[dotsteward] static: instance script tests/more.sh passed"
assert_contains "$DS_STDOUT" "[dotsteward] static checks passed (instance):"
: >"$log"

# --sandbox is passed on.
assert_exit 0 static --sandbox --only scripts
assert_eq "first root=$inst sandbox=1 pwd=$inst"$'\n'"second" "$(<"$log")"
: >"$log"

# fail from the helper: its message, exit 1, later scripts do not run.
touch "$inst/fail-first"
assert_exit 1 static --only scripts
assert_contains "$DS_STDERR" "[dotsteward] ERROR: private block failed"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: static: instance script tests/static.sh failed (exit 1)"
assert_eq "first root=$inst sandbox=0 pwd=$inst" "$(<"$log")"
rm "$inst/fail-first"
: >"$log"

# Another exit status propagates unchanged.
touch "$inst/fail-second"
assert_exit 7 static --only scripts
assert_contains "$DS_STDERR" "custom failure"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: static: instance script tests/more.sh failed (exit 7)"
rm "$inst/fail-second"
: >"$log"

# Scripts do not run when a framework contract failed.
printf '# local change\n' >>"$inst/.dotsteward/cli.sh"
assert_exit 1 static
assert_contains "$DS_STDERR" "static checks failed (instance): launcher"
assert_contains "$DS_STDERR" "instance scripts were not run"
assert_eq "" "$(<"$log")"
git -C "$inst" checkout -q -- .dotsteward/cli.sh

# A listed script that is missing or not executable is a failure.
sed -i 's|"tests/more.sh"]|"tests/more.sh", "tests/absent.sh"]|' "$inst/workstation.toml"
assert_exit 1 static --only scripts
assert_contains "$DS_STDERR" "[dotsteward] ERROR: static scripts: tests/absent.sh: instance script is missing"
: >"$log"
sed -i 's|, "tests/absent.sh"]|]|' "$inst/workstation.toml"
chmod 0644 "$inst/tests/more.sh"
assert_exit 1 static --only scripts
assert_contains "$DS_STDERR" "static scripts: tests/more.sh: instance script is not executable"
