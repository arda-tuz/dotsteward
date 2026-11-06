# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# `dotsteward host init`: this machine gets a name. Only <state>/machine.json is
# written, so the checkout stays clean and no git identity is needed. Without a
# terminal the name comes from --name, DOTSTEWARD_MACHINE or (with
# DOTSTEWARD_ASSUME_YES=1) the cleaned host name, else it is a usage error; a name
# another machine has registered needs --reuse. In a terminal the registered names
# are listed and the person answers. Running it again keeps the name; the profile
# never falls back to a default of the instance.
# shellcheck source=tests/cli/host/helpers.sh
source "$DS_REPO_ROOT/tests/cli/host/helpers.sh"

record() {
  jq -c "$1" "$(machine_file)"
}

assert_not_named() {
  [[ ! -e $(machine_file) ]] || ds_fail "machine.json was written"
}

clean_checkout() {
  assert_eq "" "$(git -C "$agents_inst" status --porcelain --untracked-files=normal)" "the checkout changed"
  assert_eq "$head" "$(git -C "$agents_inst" rev-parse HEAD)" "a commit was made"
}

head=$(git -C "$agents_inst" rev-parse HEAD)

# The machine key comes from the machine id, here a synthetic one.
export DOTSTEWARD_MACHINE_ID_FILE=$DS_TEST_ROOT/machine-id
printf '0123456789abcdef0123456789abcdef\n' >"$DOTSTEWARD_MACHINE_ID_FILE"

# --- no name to take ---------------------------------------------------------------

assert_exit 2 run_host init
assert_contains "$DS_STDERR" "--name"
assert_contains "$DS_STDERR" "DOTSTEWARD_MACHINE"
assert_not_named
for bad in Upper under_score -leading "" "$(printf 'a%.0s' {1..33})" ../escape; do
  assert_exit 2 run_host init "--name=$bad"
  assert_contains "$DS_STDERR" "invalid machine name"
  assert_not_named
done
assert_exit 2 env DOTSTEWARD_MACHINE=Upper "$agents_fw/cli/dotsteward" --instance "$agents_inst" host init </dev/null
assert_not_named

# --- a new name -------------------------------------------------------------------

assert_exit 0 run_host init --name laptop --tags nvidia,small
assert_contains "$DS_STDOUT" "laptop"
assert_contains "$DS_STDOUT" "dotsteward host publish"
assert_file_mode "$(machine_file)" 600
assert_eq '{"schema_version":1,"name":"laptop","host":{"system":"x86_64-linux","profile":null,"platform":"ubuntu-24.04","tags":["nvidia","small"]}}' \
  "$(record '{schema_version, name, host}')"
[[ $(record .machine_key) =~ ^\"[0-9a-f]{32}\"$ ]] || ds_fail "machine_key: $(record .machine_key)"
[[ $(record .named_at) =~ ^\"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\"$ ]] || ds_fail "named_at: $(record .named_at)"
clean_checkout
[[ ! -e $agents_inst/hosts ]] || ds_fail "host init wrote into the checkout"
assert_exit 0 run_e2e

# Again: the same record, also without the name; a new value of an option counts.
before=$(<"$(machine_file)")
assert_exit 0 run_host init --name laptop --tags nvidia,small
assert_eq "$before" "$(<"$(machine_file)")"
assert_exit 0 run_host init
assert_contains "$DS_STDOUT" "laptop"
assert_eq "$before" "$(<"$(machine_file)")"
key=$(record .machine_key)
named_at=$(record .named_at)
assert_exit 0 run_host init --profile fresh
assert_eq '"fresh"' "$(record .host.profile)"
assert_eq '["nvidia","small"]' "$(record .host.tags)"
assert_eq "$key" "$(record .machine_key)"
assert_eq "$named_at" "$(record .named_at)"

# Another name is a rename, which is its own command.
assert_exit 1 run_host init --name desktop
assert_contains "$DS_STDERR" "this machine is laptop"
assert_contains "$DS_STDERR" "dotsteward host rename desktop"
assert_eq '"laptop"' "$(record .name)"
rm -- "$(machine_file)"

# --- options ---------------------------------------------------------------------------

assert_exit 2 run_host init --name laptop --tags 'Not A Tag'
assert_contains "$DS_STDERR" "invalid tag"
assert_not_named
assert_exit 2 run_host init --name laptop --tags 'machine:x'
assert_not_named
assert_exit 1 run_host init --name laptop --profile nonsense
assert_contains "$DS_STDERR" "nonsense is not a profile"
assert_not_named

# The profile: --profile, then the profile of the last rebuild, never a default.
mkdir -p "$DOTSTEWARD_STATE_ROOT/current"
printf 'fresh\n' >"$DOTSTEWARD_STATE_ROOT/current/profile"
assert_exit 0 run_host init --name laptop
assert_eq '"fresh"' "$(record .host.profile)"
rm -- "$(machine_file)"
assert_exit 0 run_host init --name laptop --profile workstation
assert_eq '"workstation"' "$(record .host.profile)"
rm -- "$(machine_file)" "$DOTSTEWARD_STATE_ROOT/current/profile"

# --- the other sources of the name --------------------------------------------------------

assert_exit 0 env DOTSTEWARD_MACHINE=from-env "$agents_fw/cli/dotsteward" --instance "$agents_inst" host init </dev/null
assert_eq '"from-env"' "$(record .name)"
rm -- "$(machine_file)"

mkdir -p "$DS_TEST_ROOT/bin"
printf '#!%s\nprintf "%%s\\n" "My_Laptop-2"\n' "$BASH" >"$DS_TEST_ROOT/bin/hostname"
chmod 0755 "$DS_TEST_ROOT/bin/hostname"
assert_exit 0 env PATH="$DS_TEST_ROOT/bin:$PATH" DOTSTEWARD_ASSUME_YES=1 \
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" host init </dev/null
assert_eq '"my-laptop-2"' "$(record .name)"
rm -- "$(machine_file)"

# A host name with nothing usable in it still gives a valid name.
printf '#!%s\nprintf "%%s\\n" "___"\n' "$BASH" >"$DS_TEST_ROOT/bin/hostname"
assert_exit 0 env PATH="$DS_TEST_ROOT/bin:$PATH" DOTSTEWARD_ASSUME_YES=1 \
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" host init </dev/null
assert_eq '"machine"' "$(record .name)"
rm -- "$(machine_file)"

# --- a name another machine registered ------------------------------------------------------

write_host desktop 'profile = "fresh"
platform = "ubuntu-22.04"
tags = ["big"]
declined = { skills = ["gamma"] }'
publish_instance "chore(hosts): add desktop"
head=$(git -C "$agents_inst" rev-parse HEAD)

assert_exit 1 run_host init --name desktop
assert_contains "$DS_STDERR" "hosts/desktop.toml"
assert_contains "$DS_STDERR" "--reuse"
assert_not_named
# Under the assumption of yes too: it asks nothing, and takes over nothing.
printf '#!%s\nprintf "%%s\\n" "desktop"\n' "$BASH" >"$DS_TEST_ROOT/bin/hostname"
assert_exit 1 env PATH="$DS_TEST_ROOT/bin:$PATH" DOTSTEWARD_ASSUME_YES=1 \
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" host init </dev/null
assert_contains "$DS_STDERR" "--reuse"
assert_not_named

# A reinstall: the file stays as it is, and what it says about the machine counts.
assert_exit 0 run_host init --name desktop --reuse
assert_eq '{"name":"desktop","profile":"fresh","platform":"ubuntu-24.04","tags":["big"]}' \
  "$(record '{name, profile: .host.profile, platform: .host.platform, tags: .host.tags}')"
clean_checkout
assert_eq '{"name":"desktop","profile":"fresh","tags":["big"]}' "$(effective '{name, profile, tags}')"
rm -- "$(machine_file)"

# --- on a terminal --------------------------------------------------------------------------

# The registered names are listed; a registered name is a reinstall.
assert_exit 0 on_tty 'desktop' host init
assert_contains "$DS_STDOUT" "desktop"
assert_contains "$DS_STDOUT" "reinstall"
assert_eq '"desktop"' "$(record .name)"
assert_eq '["big"]' "$(record .host.tags)"
rm -- "$(machine_file)"

# A new name, after an invalid one.
assert_exit 0 on_tty $'Not Valid\nnew-machine' host init
assert_contains "$DS_STDOUT" "invalid machine name"
assert_eq '"new-machine"' "$(record .name)"
rm -- "$(machine_file)"

# Enter takes the suggestion, the cleaned host name.
printf '#!%s\nprintf "%%s\\n" "Suggested.example.org"\n' "$BASH" >"$DS_TEST_ROOT/bin/hostname"
assert_exit 0 env PATH="$DS_TEST_ROOT/bin:$PATH" bash -c "$(declare -f on_tty); agents_fw='$agents_fw' agents_inst='$agents_inst' on_tty \$'\\n' host init"
assert_contains "$DS_STDOUT" "[suggested]"
assert_eq '"suggested"' "$(record .name)"
rm -- "$(machine_file)"

# --name of a registered machine asks first; no is a refusal.
assert_exit 1 on_tty 'n' host init --name desktop
assert_contains "$DS_STDOUT" "reinstall"
assert_not_named
assert_exit 0 on_tty 'y' host init --name desktop
assert_eq '"desktop"' "$(record .name)"
rm -- "$(machine_file)"

# With a record the terminal asks nothing.
assert_exit 0 run_host init --name laptop
assert_exit 0 on_tty '' host init
assert_contains "$DS_STDOUT" "laptop"
assert_eq '"laptop"' "$(record .name)"
rm -- "$(machine_file)"

# --- no git identity is needed ------------------------------------------------------------

assert_exit 0 env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" host init --name laptop </dev/null
assert_eq '"laptop"' "$(record .name)"
clean_checkout

# --- the machine key -----------------------------------------------------------------------

# `systemd-id128 machine-id --app-specific` of the synthetic id: the machine, whatever
# its name, and not its machine id.
assert_eq '"37d2d95fb6514b1fb062d1276c1943ca"' "$(record .machine_key)"
rm -- "$(machine_file)"
assert_exit 0 run_host init --name other
assert_eq '"37d2d95fb6514b1fb062d1276c1943ca"' "$(record .machine_key)"
rm -- "$(machine_file)"

# Without a machine id it is random, and the record keeps it.
rm -- "$DOTSTEWARD_MACHINE_ID_FILE"
assert_exit 0 run_host init --name other
[[ $(record .machine_key) =~ ^\"[0-9a-f]{32}\"$ ]] || ds_fail "machine_key: $(record .machine_key)"
kept=$(record .machine_key)
assert_exit 0 run_host init --profile workstation
assert_eq "$kept" "$(record .machine_key)"

# A record that cannot be read is written again.
printf 'not json\n' >"$(machine_file)"
assert_exit 0 run_host init --name other
assert_contains "$DS_STDERR" "machine.json"
assert_eq '"other"' "$(record .name)"
