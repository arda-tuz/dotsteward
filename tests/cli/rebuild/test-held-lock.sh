# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# A consumer that holds back a shared lock (T19, <state>/upgrade/held-at.json) never activates it
# by hand: `rebuild --switch` of a checkout whose shared lock is the one that went red here is
# refused before anything is written, and says how to go on. --build-only activates nothing and
# --ignore-hold builds it anyway (the next `upgrade` checks it with E2E). Another lock, the
# producer itself, or a machine without a marker are never asked.
# shellcheck source=tests/cli/rebuild/helpers.sh
source "$DS_REPO_ROOT/tests/cli/rebuild/helpers.sh"

mkdir -p "$rb_inst/hosts"
printf 'schema_version = 1\n' >"$rb_inst/hosts/other-host.toml"
printf '\n[hosts]\nproducer = "other-host"\n' >>"$rb_inst/workstation.toml"
instance_commit "chore(hosts): another machine is the producer"
mkdir -p "$rb_state"
jq -n '{schema_version: 1, name: "laptop", machine_key: "00112233445566778899aabbccddeeff", named_at: "2026-01-01T00:00:00Z",
  host: {system: "x86_64-linux", profile: "workstation", platform: "ubuntu-24.04", tags: []}}' >"$rb_state/machine.json"

head=$(git -C "$rb_inst" rev-parse HEAD)
digest=$(PYTHONPATH=$rb_fw/cli/python python3 -c '
import sys
from pathlib import Path
from dotsteward_cli.upgrade import consumer
print(consumer.lock_digest(Path(sys.argv[1]), sys.argv[2]))' "$rb_inst" "$head")
# marker LOCK: this machine holds back the shared lock LOCK of the head.
marker() {
  mkdir -p "$rb_state/upgrade"
  jq -n --arg lock "$1" --arg commit "$head" '{schema_version: 1, commit: ("1" * 40), lock_commit: $commit,
    lock: $lock, components: ["example-app"], at: "2026-11-01T00:00:00Z"}' >"$rb_state/upgrade/held-at.json"
}

marker "$digest"
: >"$DS_CALL_LOG"
assert_exit 1 run_rebuild --profile workstation --switch
assert_contains "$DS_STDERR" "this machine holds back the shared lock of ${head:0:12}: it went red here (example-app)"
assert_contains "$DS_STDERR" "dotsteward upgrade"
assert_contains "$DS_STDERR" "--ignore-hold"
[[ ! -e $rb_current/activation.json ]] || ds_fail "the refusal activated something"
assert_eq 0 "$(ds_call_count nix)" "the refusal called Nix"

# Building activates nothing.
assert_exit 0 run_rebuild --profile workstation --build-only

# --ignore-hold activates it anyway.
assert_exit 0 run_rebuild --profile workstation --switch --ignore-hold
assert_eq "$head" "$(jq -r .revision "$rb_current/activation.json")"

# Another lock is no reason.
marker "$(printf '0%.0s' {1..64})"
assert_exit 0 run_rebuild --profile workstation --switch

# On the producer a marker means nothing.
marker "$digest"
sed -i 's/^producer = "other-host"$/producer = "laptop"/' "$rb_inst/workstation.toml"
instance_commit "chore(hosts): this machine is the producer"
assert_exit 0 run_rebuild --profile workstation --switch
