# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# An exact version constraint, which earlier releases accepted, stays valid: the instance upgrades,
# its gate passes, and the constraint goes to apt as it is, meaning "stay on exactly this version".
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
python3 - "$up_inst/workstation.toml" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace(
    'track = ["example-tracked-too"]\n',
    'track = ["example-tracked-too"]\nversion = "1.140.0-1"\nreason = "the extensions need exactly this build"\n',
)
open(path, "w", encoding="utf-8").write(text)
PY
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "chore: an exact constraint"
git -C "$up_inst" push -q origin HEAD:main

move example.other 3.0.0 pypi
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_eq ok "$(step_status gate)"
assert_eq ok "$(step_status publish)"
assert_eq 3.0.0 "$(git -C "$up_bare" show main:versions.lock.json | jq -r '."example.other"')"
policy=$(steps '^apt policy ' | sed -n 1p)
printf '%s\n' "${policy#apt policy }" >"$DS_TEST_ROOT/policy.json"
assert_json "$DS_TEST_ROOT/policy.json" '.kept == [{"component": "example-app", "kind": "constraint", "version": "1.140.0-1",
  "reason": "the extensions need exactly this build", "packages": ["example-tracked", "example-tracked-lib", "example-tracked-too"]}]'
