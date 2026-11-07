# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The system method: a component whose content is system files, install.system.files,
# each with its exact text and mode. A fresh install writes every file that is missing or
# differs, root-owned, through sudo and a rename, and nothing else; a second run writes
# nothing. --check-only compares the bytes and the mode. An adopted machine leaves the
# files alone until `install --component NAME` brings them in, and its --check-only says
# not managed, so a machine that has not run that sudo step stays green.
# shellcheck source=tests/cli/methods/helpers.sh
source "$DS_REPO_ROOT/tests/cli/methods/helpers.sh"

ds_use_stubs sudo
conf=/etc/example/example.conf.d/50-example.conf
script=/usr/local/lib/example/example-sync
add_component example-policy system '{"files": [
  {"path": "'"$conf"'", "text": "// Managed by dotsteward (example-policy).\nExample::Remove \"false\";\n", "mode": "0644"},
  {"path": "'"$script"'", "text": "#!/bin/sh\nexit 0\n", "mode": "0755"}
]}'
real_conf=$DS_SYSTEM_ROOT$conf
real_script=$DS_SYSTEM_ROOT$script

# --- adopt mode: not managed, also for --check-only ---------------------------------
assert_exit 0 run_install --profile workstation --check-only
assert_contains "$DS_STDOUT" "example-policy (system): not-managed: system-level method in adopt mode"
assert_exit 0 run_install --profile workstation
assert_contains "$DS_STDOUT" "not managed: example-policy"
[[ ! -e $real_conf ]] || ds_fail "adopt mode wrote a system file"

# --- the check names the first file that is missing ---------------------------------
assert_exit 1 run_install --profile fresh --check-only
assert_contains "$DS_STDERR" "example-policy (system): system file $conf is missing"
assert_exit 1 run_install --profile workstation --check-only --component example-policy
assert_contains "$DS_STDERR" "system file $conf is missing"

# --- a fresh install writes both, root-owned, through sudo --------------------------
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_contains "$DS_STDOUT" "example-policy (system): installed: 2 system files written"
assert_eq '// Managed by dotsteward (example-policy).
Example::Remove "false";' "$(<"$real_conf")"
assert_eq "$(printf '#!/bin/sh\nexit 0')" "$(<"$real_script")"
assert_file_mode "$real_conf" 644
assert_file_mode "$real_script" 755
assert_contains "$(<"$DS_CALL_LOG")" "sudo install -D -o root -g root -m 0644"
assert_contains "$(<"$DS_CALL_LOG")" "$real_conf"
assert_exit 0 run_install --profile fresh --check-only
assert_contains "$DS_STDOUT" "example-policy (system): satisfied: 2 system files as the component has them"

# --- a second run writes nothing -----------------------------------------------------
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_contains "$DS_STDOUT" "example-policy (system): satisfied: 2 system files as the component has them"
assert_not_contains "$(<"$DS_CALL_LOG")" "sudo install"

# --- a changed byte or mode is found and repaired, only that file is written ---------
printf 'Example::Remove "true";\n' >"$real_conf"
assert_exit 1 run_install --profile fresh --check-only
assert_contains "$DS_STDERR" "system file $conf differs from the component"
chmod 0700 "$real_script"
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_contains "$DS_STDOUT" "example-policy (system): installed: 2 system files written"
chmod 0755 "$real_script"
printf 'changed\n' >"$real_script"
assert_exit 1 run_install --profile fresh --check-only
assert_contains "$DS_STDERR" "system file $script differs from the component"
chmod 0644 "$real_script"
printf '#!/bin/sh\nexit 0\n' >"$real_script"
assert_exit 1 run_install --profile fresh --check-only
assert_contains "$DS_STDERR" "system file $script has mode 0644, the component 0755"
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile workstation --component example-policy
assert_contains "$DS_STDOUT" "example-policy (system): installed: 1 system file written"
assert_eq 1 "$(grep -c 'sudo install' "$DS_CALL_LOG")"
assert_exit 0 run_install --profile workstation --check-only --component example-policy

# --- a refused sudo fails the install and names the file ----------------------------
rm "$real_conf"
ds_stub_route sudo '*' --exit 1
assert_exit 1 run_install --profile fresh
assert_contains "$DS_STDERR" "example-policy (system): cannot write $conf"
