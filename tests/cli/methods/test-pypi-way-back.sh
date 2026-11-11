# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs and shell snippets are single-quoted on purpose
# A pin of a pypi application that goes back (the way back of upgrade, a pin put back by the
# producer) takes the environment back too: at-least keeps a newer version only when the owner
# installed it, never one dotsteward installed for a later pin. The method remembers the version
# it installed in the state root; the owner's own newer version still stays.
# shellcheck source=tests/cli/methods/helpers.sh
source "$DS_REPO_ROOT/tests/cli/methods/helpers.sh"
# shellcheck source=tests/lib/wheel.sh
source "$DS_REPO_ROOT/tests/lib/wheel.sh"

ds_use_stubs sudo curl
venv=$HOME/.local/share/example-app/venv
link=$HOME/.local/bin/example-app
requirements=$methods_inst/components/example-app/requirements.txt
mkdir -p "${requirements%/*}"

pin() {
  lock_set pypi.example-app "$(jq -n --arg v "$1" '{ version: $v }')"
  printf 'example-app==%s \\\n    --hash=sha256:%s\n' "$1" "$2" >"$requirements"
}

sha_100=$(ds_make_wheel example-app 1.0.0)
ds_make_wheel example-app 1.1.0 >/dev/null
sha_120=$(ds_make_wheel example-app 1.2.0)
ds_make_wheel example-app 1.3.0 >/dev/null
pin 1.0.0 "$sha_100"
add_component example-app pypi '{
  "pin": "pypi.example-app",
  "distribution": "example-app",
  "requirements": "<instance>/components/example-app/requirements.txt",
  "venv": "~/.local/share/example-app/venv",
  "bin": ["example-app"]
}'

install_app() {
  in_methods_shell 'methods_pypi_install example-app >/dev/null
    printf "%s: %s\n" "$METHODS_STATUS" "$METHODS_DETAIL"'
}
set_block() {
  manifest_edit "(.components[] | select(.name == \"example-app\") | .install) |= ($1)"
}
by_hand() {
  "$venv/bin/python" -m pip install --quiet --upgrade "example-app==$1"
}

assert_exit 0 install_app
assert_eq "installed: example-app 1.0.0" "$DS_STDOUT"

# dotsteward moves the pin and installs it.
pin 1.2.0 "$sha_120"
assert_exit 0 install_app
assert_eq "installed: example-app 1.2.0" "$DS_STDOUT"
assert_json "$DOTSTEWARD_STATE_ROOT/pypi/example-app.json" '.version == "1.2.0"'

# The pin goes back: the check says the environment is not the pin's, the install takes it back.
pin 1.0.0 "$sha_100"
assert_exit 1 run_install --profile fresh --check-only
assert_contains "$DS_STDERR" "example-app 1.0.0 or newer not found in ~/.local/share/example-app/venv (found 1.2.0, installed by dotsteward for another pin)"
assert_exit 0 install_app
assert_eq "installed: example-app 1.0.0" "$DS_STDOUT"
assert_eq "example-app 1.0.0" "$("$link")"
assert_json "$DOTSTEWARD_STATE_ROOT/pypi/example-app.json" '.version == "1.0.0"'

# The owner's own newer version stays, also after a pin that went back.
by_hand 1.3.0
assert_exit 0 install_app
assert_eq "satisfied: example-app 1.3.0 (newer than the pin 1.0.0)" "$DS_STDOUT"
assert_eq "example-app 1.3.0" "$("$link")"
