# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs and shell snippets are single-quoted on purpose
# The pypi method (a user-level Python application in its own virtual
# environment): methods_pypi_install creates the virtual environment with
# the interpreter found on the user's PATH (refusing one inside the Nix
# store), installs the hash-pinned requirements file with
# `pip install --require-hashes`, checks the installed distribution against
# the pin's exact version and links every declared console script into
# linkDir. A second run changes nothing, a new pin upgrades the
# distribution in place and keeps the packages the application installed
# into its own environment, and a foreign file at a link is refused.
# `install --check-only` fails with the rebuild hint; `install` itself
# leaves the method to `dotsteward agents install`. pip runs offline on
# wheels built by the test (tests/lib/wheel.sh).
# shellcheck source=tests/cli/methods/helpers.sh
source "$DS_REPO_ROOT/tests/cli/methods/helpers.sh"
# shellcheck source=tests/lib/wheel.sh
source "$DS_REPO_ROOT/tests/lib/wheel.sh"

ds_use_stubs sudo curl
venv=$HOME/.local/share/example-app/venv
link=$HOME/.local/bin/example-app
requirements=$methods_inst/components/example-app/requirements.txt
mkdir -p "${requirements%/*}"

# pin VERSION SHA256: the lock entry and the requirements file of example-app.
pin() {
  lock_set pypi.example-app "$(jq -n --arg v "$1" '{ version: $v }')"
  printf 'example-app==%s \\\n    --hash=sha256:%s\n' "$1" "$2" >"$requirements"
}

sha_100=$(ds_make_wheel example-app 1.0.0)
sha_110=$(ds_make_wheel example-app 1.1.0)
ds_make_wheel example-extra 0.1.0 >/dev/null
pin 1.0.0 "$sha_100"
install_block='{
  "pin": "pypi.example-app",
  "distribution": "example-app",
  "requirements": "<instance>/components/example-app/requirements.txt",
  "python": "python3",
  "venv": "~/.local/share/example-app/venv",
  "bin": ["example-app"],
  "linkDir": "~/.local/bin",
  "pathAppend": true
}'
add_component example-app pypi "$install_block"

install_app() {
  in_methods_shell 'methods_pypi_install example-app >/dev/null
    printf "%s: %s\n" "$METHODS_STATUS" "$METHODS_DETAIL"'
}
set_block() {
  manifest_edit "(.components[] | select(.name == \"example-app\") | .install) |= ($1)"
}

# `install --check-only` reports the missing environment with the rebuild
# hint; `install` leaves it to the agents installer.
assert_exit 1 run_install --profile fresh --check-only
assert_eq "[dotsteward] ERROR: example-app (pypi): example-app 1.0.0 not found in ~/.local/share/example-app/venv (found none); run 'dotsteward rebuild --profile fresh --switch'" "$DS_STDERR"
assert_exit 0 run_install --profile fresh
assert_contains "$DS_STDOUT" "[dotsteward] example-app (pypi): skipped: installed by dotsteward agents install"
# Adopt mode checks it the same way (user level).
assert_exit 1 run_install --profile workstation --check-only
assert_contains "$DS_STDERR" "run 'dotsteward rebuild --profile workstation --switch'"

# Install from nothing: the environment, the pinned distribution, the link.
assert_exit 0 install_app
assert_eq "installed: example-app 1.0.0" "$DS_STDOUT"
assert_symlink_to "$link" "$venv/bin/example-app"
assert_eq "example-app 1.0.0" "$("$link")"
[[ -x $venv/bin/python ]] || ds_fail "the virtual environment has no interpreter"
assert_eq "0" "$(ds_call_count sudo)"
assert_eq "0" "$(ds_call_count curl)"
assert_exit 0 run_install --profile fresh --check-only
assert_contains "$DS_STDOUT" "[dotsteward] example-app (pypi): satisfied: example-app 1.0.0"

# A second run changes nothing.
before=$(stat -c %Y -- "$venv/bin/python")
assert_exit 0 install_app
assert_eq "satisfied: example-app 1.0.0" "$DS_STDOUT"
assert_eq "$before" "$(stat -c %Y -- "$venv/bin/python")"

# The application installs a package into its own environment; a new pin
# upgrades the distribution in place and keeps that package.
"$venv/bin/python" -m pip install --quiet example-extra
pin 1.1.0 "$sha_110"
assert_exit 1 run_install --profile fresh --check-only
assert_contains "$DS_STDERR" "example-app 1.1.0 not found in ~/.local/share/example-app/venv (found 1.0.0)"
assert_exit 0 install_app
assert_eq "installed: example-app 1.1.0" "$DS_STDOUT"
assert_eq "example-app 1.1.0" "$("$link")"
assert_eq "example-extra 0.1.0" "$("$venv/bin/example-extra")"

# A link that is missing is a failed check and is recreated by the install.
rm -- "$link"
assert_exit 1 run_install --profile fresh --check-only
assert_contains "$DS_STDERR" "example-app (pypi): ~/.local/bin/example-app does not link to $venv/bin/example-app; run 'dotsteward rebuild --profile fresh --switch'"
assert_exit 0 install_app
assert_eq "installed: example-app 1.1.0" "$DS_STDOUT"
assert_symlink_to "$link" "$venv/bin/example-app"

# A foreign file at a link is refused and left alone.
rm -- "$link"
printf 'a file of the user\n' >"$link"
assert_exit 1 install_app
assert_contains "$DS_STDERR" "example-app (pypi): refusing to replace $link, which is not a link into $venv"
assert_eq "a file of the user" "$(<"$link")"
rm -- "$link"
ln -s /usr/bin/true "$link"
assert_exit 1 install_app
assert_contains "$DS_STDERR" "refusing to replace $link, which is not a link into $venv"
rm -- "$link"

# The requirements file must pin the distribution at the lock's version.
lock_set pypi.example-app '{ "version": "1.2.0" }'
assert_exit 1 install_app
assert_contains "$DS_STDERR" "example-app (pypi): $requirements does not pin example-app==1.2.0"
pin 1.1.0 "$sha_110"

# pip verifies every hash: a wrong one installs nothing.
rm -rf -- "$venv"
pin 1.1.0 "$(printf '0%.0s' {1..64})"
assert_exit 1 install_app
assert_contains "$DS_STDERR" "example-app (pypi): pip install failed"
[[ ! -e $link && ! -L $link ]] || ds_fail "a failed install created the link"
pin 1.1.0 "$sha_110"

# An interpreter inside the Nix store is refused before anything is created.
rm -rf -- "$venv"
store=$(python3 -c 'import sys; print(sys.base_prefix)')
NIX_STORE_DIR=$store assert_exit 1 install_app
assert_contains "$DS_STDERR" "example-app (pypi): the interpreter python3 lives in the Nix store"
[[ ! -e $venv ]] || ds_fail "a refused interpreter created the environment"

# A missing interpreter.
set_block '.python = "example-python-missing"'
assert_exit 1 install_app
assert_contains "$DS_STDERR" "example-app (pypi): example-python-missing not found on PATH"
set_block '.python = "python3"'

# A virtual environment whose interpreter no longer runs is reported, never
# removed.
assert_exit 0 install_app
rm -- "$venv/bin/python"
printf '#!/bin/sh\nexit 1\n' >"$venv/bin/python"
chmod 0755 "$venv/bin/python"
assert_exit 1 install_app
assert_contains "$DS_STDERR" "example-app (pypi): the virtual environment $venv does not run; remove it and run 'dotsteward agents install' again"
[[ -d $venv ]] || ds_fail "a broken environment was removed"

# Invalid install blocks.
set_block '.bin = ["../example-app"]'
assert_exit 1 install_app
assert_contains "$DS_STDERR" "example-app (pypi): invalid console script name: ../example-app"
set_block '.venv = "relative/venv"'
assert_exit 1 install_app
assert_contains "$DS_STDERR" "example-app (pypi): venv must be ~/... or absolute: relative/venv"
