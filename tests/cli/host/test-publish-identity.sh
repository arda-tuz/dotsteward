# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# `dotsteward host publish` from a person's real git identity, an ordinary e-mail address
# that the public policy of the framework refuses in its own commits. What lands in a
# private instance is scanned like everything else there: with the policy of the instance,
# on the content. The identity of the commit is not content; a secret, a denylist term, a
# forbidden path or a file rule in the host file still stops the publish.
# shellcheck source=tests/cli/host/helpers.sh
source "$DS_REPO_ROOT/tests/cli/host/helpers.sh"

at=@
person_email="owner.name${at}mail.provider.test"
person_name="Owner Name"
git config --global user.name "$person_name"
git config --global user.email "$person_email"

remote_tip() {
  git -C "$e2e_bare" rev-parse refs/heads/main
}

remote_file() {
  git -C "$e2e_bare" show "refs/heads/main:hosts/$1.toml"
}

# set_privacy TOML: the [privacy] table of workstation.toml is TOML.
base_config=$DS_TEST_ROOT/workstation.base.toml
cp -- "$agents_inst/workstation.toml" "$base_config"
set_privacy() {
  cp -- "$base_config" "$agents_inst/workstation.toml"
  printf '\n[privacy]\n%s\n' "$1" >>"$agents_inst/workstation.toml"
}

# edit_remote_file TEXT: another clone replaces hosts/laptop.toml on the remote.
clone=$DS_TEST_ROOT/clone
git clone -q "$e2e_bare" "$clone"
edit_remote_file() {
  git -C "$clone" pull -q --ff-only origin main
  mkdir -p "$clone/hosts"
  printf '%s\n' "$1" >"$clone/hosts/laptop.toml"
  git -C "$clone" add -A
  git -C "$clone" commit -q -m "chore(hosts): edit laptop"
  git -C "$clone" push -q origin main
}

# --- the real identity of a person -----------------------------------------------------------

assert_exit 0 run_host init --name laptop --tags small --profile workstation
assert_exit 0 run_host publish
assert_contains "$DS_STDOUT" "published hosts/laptop.toml"
assert_eq "$person_email" "$(git -C "$e2e_bare" log -1 --format=%ae "$(remote_tip)")"
assert_contains "$(remote_file laptop)" 'tags = ["small"]'

# No identity here: the author of the first commit, the owner of the instance, publishes alike,
# not the author of the tip.
owner_email=$(git -C "$e2e_bare" log -1 --format=%ae "$(git -C "$e2e_bare" rev-list --max-parents=0 main)")
[[ $owner_email != "$person_email" ]] || ds_fail "the first commit is already the person's"
assert_exit 0 run_host init --tags second
assert_exit 0 env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" host publish </dev/null
assert_eq "$owner_email" "$(git -C "$e2e_bare" log -1 --format=%ae "$(remote_tip)")"
assert_contains "$(remote_file laptop)" 'tags = ["second"]'

# The denylist holds the name of the person: not in the file, so no finding.
denylist=$DS_TEST_ROOT/denylist.txt
printf '%s\n%s\n' "$person_name" "$person_email" >"$denylist"
set_privacy "denylist = \"$denylist\""
assert_exit 0 run_host init --tags third
assert_exit 0 run_host publish
assert_contains "$(remote_file laptop)" 'tags = ["third"]'

# Personal text is at home in an instance: a reason in another language stays.
reason=$(printf 'nicht f\303\274r diese Maschine')
edit_remote_file "schema_version = 1
platform = \"ubuntu-24.04\"

[holds.example]
version = \"1.2.3\"
reason = \"$reason\""
cp -- "$base_config" "$agents_inst/workstation.toml"
assert_exit 0 run_host init --tags fourth
assert_exit 0 run_host publish
assert_contains "$(remote_file laptop)" "$reason"
assert_contains "$(remote_file laptop)" 'tags = ["fourth"]'

# --- what still stops a publish -----------------------------------------------------------------

stopped() {
  local before
  before=$(remote_tip)
  assert_exit 4 run_host publish
  assert_contains "$DS_STDERR" "the privacy scan found something in hosts/laptop.toml"
  assert_eq "$before" "$(remote_tip)" "a finding was published"
}

# A term of the denylist in the file.
printf 'denied-tag\n' >"$denylist"
set_privacy "denylist = \"$denylist\""
assert_exit 0 run_host init --tags denied-tag
stopped
assert_not_contains "$DS_STDOUT$DS_STDERR" 'tags ='
cp -- "$base_config" "$agents_inst/workstation.toml"

# A forbidden path, and a file rule of the instance.
set_privacy 'forbidden_paths = ["hosts/*"]'
stopped
set_privacy '[[privacy.file_rules]]
message = "no tags here"
pattern = "denied-tag"
files = ["hosts/*.toml"]'
stopped
cp -- "$base_config" "$agents_inst/workstation.toml"

# A secret in the file: the generic rules hold, and the match is never printed.
secret=$(fake_secret ghp_ 36)
edit_remote_file "schema_version = 1

[holds.example]
version = \"1.2.3\"
reason = \"$secret\""
stopped
assert_not_contains "$DS_STDOUT$DS_STDERR" "$secret"
