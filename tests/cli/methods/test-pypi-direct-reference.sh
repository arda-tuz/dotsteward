# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs and shell snippets are single-quoted on purpose
# The pypi method with a direct reference: an application that is not on
# the index under its name (or whose index name belongs to another project)
# is pinned as `NAME @ URL --hash=sha256:...`, the exact archive the hash
# names. The requirements then pin the distribution as exactly as `NAME==V`
# does, so the method installs it, and the installed distribution must
# still report the pin's version. A direct reference of another name does
# not pin the distribution.
# shellcheck source=tests/cli/methods/helpers.sh
source "$DS_REPO_ROOT/tests/cli/methods/helpers.sh"
# shellcheck source=tests/lib/wheel.sh
source "$DS_REPO_ROOT/tests/lib/wheel.sh"

link=$HOME/.local/bin/example-app
requirements=$methods_inst/components/example-app/requirements.txt
mkdir -p "${requirements%/*}"

sha=$(ds_make_wheel example-app 1.0.0)
wheel=$DS_WHEELS/example_app-1.0.0-py3-none-any.whl
# direct NAME VERSION: the lock pins VERSION; the requirements reference the
# 1.0.0 wheel of example-app as NAME.
direct() {
  lock_set pypi.example-app "$(jq -n --arg v "$2" '{ version: $v }')"
  printf '%s @ file://%s \\\n    --hash=sha256:%s\n' "$1" "$wheel" "$sha" >"$requirements"
}
add_component example-app pypi '{
  "pin": "pypi.example-app",
  "distribution": "example-app",
  "requirements": "<instance>/components/example-app/requirements.txt",
  "python": "python3",
  "venv": "~/.local/share/example-app/venv",
  "bin": ["example-app"],
  "linkDir": "~/.local/bin",
  "pathAppend": false
}'

install_app() {
  in_methods_shell 'methods_pypi_install example-app >/dev/null
    printf "%s: %s\n" "$METHODS_STATUS" "$METHODS_DETAIL"'
}

direct example-app 1.0.0
assert_exit 0 install_app
assert_eq "installed: example-app 1.0.0" "$DS_STDOUT"
assert_eq "example-app 1.0.0" "$("$link")"
assert_exit 0 install_app
assert_eq "satisfied: example-app 1.0.0" "$DS_STDOUT"

# The name is matched like a PEP 503 normalized name (read when the
# environment has to be installed).
rm -rf -- "$HOME/.local/share/example-app" "$link"
direct Example_App 1.0.0
assert_exit 0 install_app
assert_eq "installed: example-app 1.0.0" "$DS_STDOUT"

# The archive's version must still be the pin's version.
direct example-app 1.1.0
assert_exit 1 install_app
assert_contains "$DS_STDERR" "example-app 1.1.0"

# A direct reference of another distribution does not pin this one (read
# when the environment has to be installed).
rm -rf -- "$HOME/.local/share/example-app" "$link"
direct example-application 1.0.0
assert_exit 1 install_app
assert_contains "$DS_STDERR" "example-app (pypi): $requirements does not pin example-app==1.0.0"
