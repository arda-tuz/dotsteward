# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs and shell snippets are single-quoted on purpose
# The pypi method finds its interpreter on the user's PATH and also runs it
# there, without the CLI's own toolchain. A version-manager shim (here one
# that, like a "system" version, looks python3 up again on PATH after
# removing its own directory) then reaches the user's interpreter, never the
# toolchain's, which here refuses to run anything but the CLI's own modules.
# shellcheck source=tests/cli/methods/helpers.sh
source "$DS_REPO_ROOT/tests/cli/methods/helpers.sh"
# shellcheck source=tests/lib/wheel.sh
source "$DS_REPO_ROOT/tests/lib/wheel.sh"

venv=$HOME/.local/share/example-app/venv
requirements=$methods_inst/components/example-app/requirements.txt
toolchain=$DS_TEST_ROOT/toolchain
shims=$DS_TEST_ROOT/shims
mkdir -p "${requirements%/*}" "$toolchain" "$shims"

# The toolchain's python3 runs the CLI's own modules and refuses (and
# records) everything else.
real_python=$(python3 -c 'import sys; print(sys.executable)')
cat >"$toolchain/python3" <<EOF
#!$BASH
[[ " \$* " == *" -m dotsteward_cli."* ]] && exec '$real_python' "\$@"
printf 'toolchain python3 %s\n' "\$*" >>'$DS_TEST_ROOT/toolchain-calls'
exit 1
EOF
cat >"$shims/python3" <<EOF
#!$BASH
PATH=\$(printf '%s' "\$PATH" | tr ':' '\n' | grep -vxF '$shims' | paste -sd: -)
exec python3 "\$@"
EOF
chmod 0755 "$toolchain/python3" "$shims/python3"

sha=$(ds_make_wheel example-app 1.0.0)
lock_set pypi.example-app '{ "version": "1.0.0" }'
printf 'example-app==1.0.0 --hash=sha256:%s\n' "$sha" >"$requirements"
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
  PATH="$toolchain:$shims:$PATH" DOTSTEWARD_TOOLCHAIN_PATH=$toolchain \
    in_methods_shell 'methods_pypi_install example-app >/dev/null
      printf "%s: %s\n" "$METHODS_STATUS" "$METHODS_DETAIL"'
}

assert_exit 0 install_app
assert_eq "installed: example-app 1.0.0" "$DS_STDOUT"
assert_eq "example-app 1.0.0" "$("$HOME/.local/bin/example-app")"
[[ ! -e $DS_TEST_ROOT/toolchain-calls ]] ||
  ds_fail "the toolchain interpreter ran: $(<"$DS_TEST_ROOT/toolchain-calls")"
[[ -x $venv/bin/python ]] || ds_fail "the virtual environment has no interpreter"
