# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Phase 1 of `dotsteward agents` also installs every active component whose
# method is pypi at the user level, in both profile modes: its virtual
# environment, the hash-pinned requirements and the console script links.
# check fails with the rebuild hint when the environment, the version or a
# link is missing, and changes nothing. A failed install stops before the
# skill layout; components not active in the profile are left alone.
# shellcheck source=tests/agents/helpers.sh
source "$DS_REPO_ROOT/tests/agents/helpers.sh"
# shellcheck source=tests/lib/wheel.sh
source "$DS_REPO_ROOT/tests/lib/wheel.sh"

venv=$HOME/.local/share/example-term/venv
link=$HOME/.local/bin/example-term
mkdir -p "$agents_inst/components/example-term"
sha=$(ds_make_wheel example-term 1.1.0)
printf 'example-term==1.1.0 --hash=sha256:%s\n' "$sha" >"$agents_inst/components/example-term/requirements.txt"
lock_set pypi.example-term '{ "version": "1.1.0" }'
lock_set pypi.example-app '{ "version": "1.0.0" }'
add_component example-term pypi '{
  "pin": "pypi.example-term",
  "distribution": "example-term",
  "requirements": "<instance>/components/example-term/requirements.txt",
  "python": "python3",
  "venv": "~/.local/share/example-term/venv",
  "bin": ["example-term"],
  "linkDir": "~/.local/bin",
  "pathAppend": false
}'
# Not active in the check profile: never installed by it.
add_component example-app pypi '{
  "pin": "pypi.example-app",
  "distribution": "example-app",
  "requirements": "<instance>/components/example-app/requirements.txt",
  "python": "python3",
  "venv": "~/.local/share/example-app/venv",
  "bin": ["example-app"],
  "linkDir": "~/.local/bin",
  "pathAppend": false
}' '["fresh"]'

before=$(home_state)
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "example-term (pypi): example-term 1.1.0 not found in ~/.local/share/example-term/venv (found none); run 'dotsteward rebuild --profile workstation --switch'"
assert_eq "$before" "$(home_state)"
assert_exit 1 run_agents check --json
assert_eq '"pypi-failed"' "$(jq -c '.findings[0].code' <<<"$DS_STDOUT")"

assert_exit 0 run_agents install
assert_contains "$DS_STDOUT" "example-term (pypi): installed example-term 1.1.0"
assert_symlink_to "$link" "$venv/bin/example-term"
assert_eq "example-term 1.1.0" "$("$link")"
[[ ! -e $HOME/.local/share/example-app ]] || ds_fail "a component of another profile was installed"
assert_exit 0 run_agents check

# Install failures stop before the layout.
rm -rf "$HOME/.agents" "$link"
printf 'a file of the user\n' >"$link"
assert_exit 1 run_agents install
assert_contains "$DS_STDERR" "refusing to replace $link, which is not a link into $venv"
[[ ! -e $HOME/.agents ]] || ds_fail "phase 1 runs before the layout"
