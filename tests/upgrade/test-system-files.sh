# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# The sudo window writes the files of the active system components that are missing or
# differ, after the pin file and before apt moves anything, each through `sudo install`; a
# second run writes nothing. A system component of another profile and one this machine
# leaves out are not touched; without a terminal the window waits as it always does.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude
dropin=/etc/example/example.conf.d/50-example.conf
other=/etc/example/example.conf.d/50-other.conf
text='// Managed by dotsteward (example-policy).
Example::Remove "false";
'
cat >>"$up_inst/workstation.toml" <<'TOML'

[components.example-policy]
enable = true

[components.example-elsewhere]
enable = true
TOML
jq --arg path "$dropin" --arg other "$other" --arg text "$text" '.components += [
  {name: "example-policy", method: "system", profiles: null, platforms: ["linux"],
   install: {files: [{path: $path, text: $text, mode: "0644"}]}},
  {name: "example-elsewhere", method: "system", profiles: ["another"], platforms: ["linux"],
   install: {files: [{path: $other, text: "other\n", mode: "0644"}]}}
]' "$mirror" >"$mirror.new"
mv "$mirror.new" "$mirror"
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "chore: add the system components"
git -C "$up_inst" push -q origin HEAD:main

# Without a terminal nothing is written: the sudo steps wait.
assert_exit 3 upgrade --tracked
[[ ! -e $DS_SYSTEM_ROOT$dropin ]] || ds_fail "a run without a terminal wrote a system file"

clear_log
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_order '^apt policy' "^sudo -n install -D -o root -g root -m 0644 .* $DS_SYSTEM_ROOT$dropin\$" '^apt commit'
assert_eq "$text" "$(<"$DS_SYSTEM_ROOT$dropin")
"
assert_file_mode "$DS_SYSTEM_ROOT$dropin" 644
assert_eq ok "$(step_status system:example-policy)"
[[ ! -e $DS_SYSTEM_ROOT$other ]] || ds_fail "the system component of another profile was written"
assert_no_step "50-other.conf"

# As the component has it: nothing to write.
clear_log
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_no_step '^sudo -n install '
assert_eq ok "$(step_status system:example-policy)"

# A changed file is written again.
printf 'changed\n' >"$DS_SYSTEM_ROOT$dropin"
clear_log
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_order '^apt policy' "^sudo -n install .* $DS_SYSTEM_ROOT$dropin\$"
assert_eq "$text" "$(<"$DS_SYSTEM_ROOT$dropin")
"
