# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs and child scripts are single-quoted on purpose
# `dotsteward observe` waits until dpkg has settled before it reads anything, and only then
# takes the instance lock, so that an apt run of the owner is never observed half done and
# `upgrade` is not kept waiting meanwhile. Settled means: no process holds a lock of
# /var/lib/dpkg/lock-frontend, /var/lib/dpkg/lock, /var/lib/apt/lists/lock or
# /var/cache/apt/archives/lock (as /proc/locks lists them, whatever the program), an empty
# /var/lib/dpkg/updates, a clean `dpkg --audit`, and a status file that stayed the same for
# --settle-seconds (default 15), counted from the last moment it saw dpkg at work. While a
# lock is held it waits without a limit; for the other signs, after --wait-limit seconds
# (default 1800) it gives up and observes nothing; the next change of the status file starts
# it again. A busy instance
# lock leaves a pending mark (exit 3), and the holder starts the observer when it lets go.
# shellcheck source=tests/cli/host/observe-helpers.sh
source "$DS_REPO_ROOT/tests/cli/host/observe-helpers.sh"

add_component example-editor deb '{"packageNames": ["example-editor"]}'
publish_instance "chore: one component"
pkg example-editor 1.2.3-1
pkg unrelated-package 9.9
name_machine laptop
snapshot=$DOTSTEWARD_STATE_ROOT/observe/dpkg-snapshot.json

# --- each sign of a running dpkg or apt keeps it waiting, then it gives up -----------------

busy() {
  assert_exit 0 run_observe --wait-limit 0
  assert_contains "$DS_STDOUT" "dpkg did not settle within 0 s ($1): nothing was observed"
  [[ ! -e $snapshot ]] || ds_fail "an unsettled dpkg was observed ($1)"
  assert_eq "" "$(state_tip)"
}

: >"$dpkg_dir/updates/0001"
busy "/var/lib/dpkg/updates holds unfinished work"
rm -f -- "$dpkg_dir/updates/0001"

ds_stub_set dpkg audit "The following packages are only half configured, probably due to problems
configuring them the first time.  The configuration should be retried using
dpkg --configure <package> or the configure menu option in dselect:
 example-editor       An example editor"
busy "dpkg --audit reports a problem"
ds_stub_set dpkg audit ""

# --- dpkg settles while it waits: the observer goes on ----------------------------------

: >"$DS_CALL_LOG"
ds_stub_override dpkg <<SH
#!/usr/bin/env bash
if [[ \$1 == --audit && ! -e $DS_TEST_ROOT/audited ]]; then
  : >"$DS_TEST_ROOT/audited"
  printf ' example-editor       An example editor\n'
  exit 0
fi
[[ \$1 == --audit ]] && exit 0
printf 'dpkg override: unexpected call: %s\n' "\$*" >&2
exit 99
SH
assert_exit 0 run_observe --wait-limit 60
assert_contains "$DS_STDOUT" "the first observation"
assert_call_count 2 dpkg --audit
rm -f -- "$DS_STUB_STATE/dpkg/override"

# --- a lock of dpkg or apt keeps it waiting, without a limit while the lock is there ----------

locked() {
  local line=$1
  pkg unrelated-package "$2"
  printf '%s\n' "$line" >"$DS_SYSTEM_ROOT/proc/locks"
  (sleep 1 && : >"$DS_SYSTEM_ROOT/proc/locks") &
  local releaser=$! started=$SECONDS
  assert_exit 0 run_observe --wait-limit 0
  wait "$releaser"
  ((SECONDS - started >= 1)) || ds_fail "the observer went on while a lock was held: $line"
  assert_contains "$DS_STDOUT" "1 package changed since the last observation"
  assert_eq "$2" "$(jq -r '.packages["unrelated-package"]' "$snapshot")"
}

version=0
for lock in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock; do
  version=$((version + 1))
  locked "$(lock_line "$lock")" "9.$version"
done
# A waiter on the lock (the kernel marks it "->") and a flock of another program count too.
locked "$(lock_line /var/lib/dpkg/lock | sed 's/^1: POSIX /1: -> FLOCK /')" 9.8

# A lock of another file, or of the same inode on another device, is no sign of dpkg.
: >"$DS_SYSTEM_ROOT/run/other.lock"
{
  lock_line /run/other.lock
  printf '2: FLOCK  ADVISORY  WRITE 4243 ff:ff:%s 0 EOF\n' "$(stat -c '%i' "$DS_SYSTEM_ROOT/var/lib/dpkg/lock")"
} >"$DS_SYSTEM_ROOT/proc/locks"
assert_exit 0 run_observe --wait-limit 0
assert_contains "$DS_STDOUT" "no package changed since the last observation"
: >"$DS_SYSTEM_ROOT/proc/locks"

# --- the status file changes while it waits: it waits again and reads the newer one ---------

rm -f -- "$DS_TEST_ROOT/audited"
ds_stub_override dpkg <<SH
#!/usr/bin/env bash
if [[ \$1 == --audit && ! -e $DS_TEST_ROOT/audited ]]; then
  : >"$DS_TEST_ROOT/audited"
  # The rest of an apt run lands meanwhile.
  printf 'Package: late-package\nStatus: install ok installed\nVersion: 1.0\nArchitecture: amd64\n' \
    >"$DS_STUB_STATE/dpkg/installed/late-package"
  { printf '\n'; cat "$DS_STUB_STATE/dpkg/installed/late-package"; } >>"$dpkg_dir/status"
  exit 0
fi
[[ \$1 == --audit ]] && exit 0
printf 'dpkg override: unexpected call: %s\n' "\$*" >&2
exit 99
SH
pkg unrelated-package 10.0
assert_exit 0 run_observe --wait-limit 60
assert_contains "$DS_STDOUT" "2 packages changed since the last observation"
assert_eq "10.0" "$(jq -r '.packages["unrelated-package"]' "$snapshot")"
assert_eq "1.0" "$(jq -r '.packages["late-package"]' "$snapshot")"
rm -f -- "$DS_STUB_STATE/dpkg/override"

# --- the status file must stay the same for --settle-seconds -------------------------------

pkg unrelated-package 11.0
started=$SECONDS
assert_exit 0 run_observe --settle-seconds 2
((SECONDS - started >= 2)) || ds_fail "the observer did not wait for the status file to stay the same"
assert_contains "$DS_STDOUT" "1 package changed since the last observation"

# --- a busy instance lock: a pending mark, and the holder starts the observer ----------------

work=$DS_TEST_ROOT/lock-work
mkdir -p "$work"
PYTHONPATH=$agents_fw/cli/python PYTHONDONTWRITEBYTECODE=1 python3 -s -P -m dotsteward_cli.internal lock run \
  --holder upgrade --state-root "$DOTSTEWARD_STATE_ROOT" -- bash "$DS_REPO_ROOT/tests/lib/hold.sh" \
  "$work/started" "$work/release" &
holder_pid=$!
tries=0
until [[ -e $work/started ]]; do
  tries=$((tries + 1))
  ((tries < 1500)) || ds_fail "the holder did not start"
  sleep 0.02
done

# The pending run gets a small environment: the stubs it calls find the harness through
# wrappers that know it.
wrappers=$DS_TEST_ROOT/pending-bin
mkdir -p "$wrappers"
for name in dpkg dpkg-query notify-send; do
  printf '#!%s\nexport DS_CALL_LOG=%q DS_STUB_STATE=%q\nexec %q "$@"\n' "$BASH" "$DS_CALL_LOG" "$DS_STUB_STATE" \
    "$DS_REPO_ROOT/tests/lib/stubs/$name" >"$wrappers/$name"
  chmod 0755 "$wrappers/$name"
done
export PATH=$wrappers:$PATH

# The pending run has no fake SSH transport: its record stays on this machine.
printf '\n[policy]\nobserved_state_push = false\n' >>"$agents_inst/workstation.toml"
commit_instance "chore: keep the state here"
pkg unrelated-package 12.0
before=$(state_tip)
assert_exit 3 run_observe
assert_contains "$DS_STDERR" "the instance lock is held by upgrade; observe runs when it is free"
assert_eq "11.0" "$(jq -r '.packages["unrelated-package"]' "$snapshot")"
assert_json "$DOTSTEWARD_STATE_ROOT/instance.pending/observe.json" \
  '.name == "observe" and (.argv | index("observe")) != null and (.argv | index("--instance")) != null'
: >"$work/release"
wait "$holder_pid"
tries=0
until [[ $(jq -r '.packages["unrelated-package"]' "$snapshot") == 12.0 ]]; do
  tries=$((tries + 1))
  ((tries < 1500)) || ds_fail "the pending observer did not run: $(cat "$DOTSTEWARD_STATE_ROOT/instance.pending/observe.log" 2>&1)"
  sleep 0.02
done
assert_contains "$(<"$DOTSTEWARD_STATE_ROOT/instance.pending/observe.log")" "1 package changed since the last observation"
[[ $(state_tip) != "$before" ]] || ds_fail "the pending observer recorded nothing"
