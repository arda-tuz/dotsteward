# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs and shell snippets are single-quoted on purpose
# The owner upgrades a pypi application by hand in its environment (`pip install -U`): the
# method keeps the newer version, as official-binary does with its at-least policy. The check
# passes and says so, the install never moves it back, and a pin that moves past it upgrades
# it again. `policy = "exact"` holds the environment to the pin's version.
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

# The owner's newer version passes the check and stays.
by_hand 1.1.0
assert_exit 0 run_install --profile fresh --check-only
assert_contains "$DS_STDOUT" "[dotsteward] example-app (pypi): satisfied: example-app 1.1.0 (newer than the pin 1.0.0)"
assert_exit 0 install_app
assert_eq "satisfied: example-app 1.1.0 (newer than the pin 1.0.0)" "$DS_STDOUT"
assert_eq "example-app 1.1.0" "$("$link")"

# A pin past it upgrades it.
pin 1.2.0 "$sha_120"
assert_exit 1 run_install --profile fresh --check-only
assert_contains "$DS_STDERR" "example-app 1.2.0 or newer not found in ~/.local/share/example-app/venv (found 1.1.0)"
assert_exit 0 install_app
assert_eq "installed: example-app 1.2.0" "$DS_STDOUT"
assert_eq "example-app 1.2.0" "$("$link")"

# exact: the environment is held to the pin, a newer version goes back.
set_block '.policy = "exact"'
by_hand 1.3.0
assert_exit 1 run_install --profile fresh --check-only
assert_contains "$DS_STDERR" "example-app 1.2.0 exactly not found in ~/.local/share/example-app/venv (found 1.3.0)"
assert_exit 0 install_app
assert_eq "installed: example-app 1.2.0" "$DS_STDOUT"
assert_eq "example-app 1.2.0" "$("$link")"

set_block '.policy = "newest"'
assert_exit 1 install_app
assert_contains "$DS_STDERR" "example-app (pypi): unknown policy: newest"
