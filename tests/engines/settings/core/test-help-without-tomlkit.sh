# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# `dotsteward settings --help` works with a python3 that lacks tomlkit (the
# skill contract asks every documented command for its help, outside the
# package too), and every command then stops with exit 2 and a message that
# names tomlkit instead of a Python traceback. The python3 on PATH is wrapped
# so that importing tomlkit fails whether or not it is installed.

# The interpreter itself, not a launcher that looks python3 up on PATH again.
real_python=$(python3 -c 'import sys; print(sys.executable)') ||
  ds_fail "the settings tests need python3 on PATH"
[[ -x $real_python ]] || ds_fail "python3 reports no executable interpreter: [$real_python]"
blocked=$DS_TEST_ROOT/no-tomlkit
mkdir -p "$blocked/lib" "$blocked/bin"
cat >"$blocked/lib/tomlkit.py" <<'PY'
raise ModuleNotFoundError("No module named 'tomlkit'", name="tomlkit")
PY
cat >"$blocked/bin/python3" <<SH
#!$BASH
PYTHONPATH=$blocked/lib\${PYTHONPATH:+:\$PYTHONPATH} exec $(printf '%q' "$real_python") "\$@"
SH
chmod 0755 "$blocked/bin/python3"
export PATH=$blocked/bin:$PATH

# The wrapper really hides tomlkit.
assert_exit 1 python3 -c 'import tomlkit'

settings() {
  "$DS_REPO_ROOT/cli/dotsteward" settings "$@"
}

assert_exit 0 settings --help
assert_contains "$DS_STDOUT" "usage: local-maintained-files"
assert_contains "$DS_STDOUT" "reconcile"
assert_exit 0 settings status --help
assert_contains "$DS_STDOUT" "--json"
assert_exit 0 settings resolve --help
assert_contains "$DS_STDOUT" "--local"

repo=$DS_TEST_ROOT/repo
mkdir -p "$repo"
git init -q -b main "$repo"
for command in status apply flush reconcile verify validate; do
  assert_exit 2 settings --repo "$repo" --home "$HOME" --state-dir "$DS_TEST_ROOT/settings-state" "$command"
  assert_contains "$DS_STDERR" "[local-maintained-files] ERROR:" "$command"
  assert_contains "$DS_STDERR" "tomlkit" "$command"
  assert_not_contains "$DS_STDERR" "Traceback" "$command"
done
[[ ! -e $DS_TEST_ROOT/settings-state ]] || ds_fail "a command without tomlkit created the state directory"
