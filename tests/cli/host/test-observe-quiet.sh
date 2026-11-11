# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# What settled means for `dotsteward observe`, in the corners:
# - Quiet is counted from the last moment dpkg or apt was seen at work: a lock held while the
#   status file stays the same is no quiet time, so a second apt command right after the
#   first is not observed half done.
# - While a lock is visibly held the observer waits without a limit (the holder is alive, and
#   no later write of the status file may come to start it again); --wait-limit bounds only
#   the waiting for the other signs.
# - A lock matches by device and inode: the device stat gives, or the one of the superblock
#   of its mount (btrfs subvolumes: /proc/self/mountinfo). Without that, a lock of the same
#   inode on another anonymous device (major 0) may be dpkg's: it keeps the observer waiting
#   only up to --wait-limit.
# - A snapshot that is no JSON object is no snapshot: the next run takes a new baseline.
# shellcheck source=tests/cli/host/observe-helpers.sh
source "$DS_REPO_ROOT/tests/cli/host/observe-helpers.sh"

add_component example-editor deb '{"packageNames": ["example-editor"]}'
publish_instance "chore: one component"
pkg example-editor 1.2.3-1
name_machine laptop
snapshot=$DOTSTEWARD_STATE_ROOT/observe/dpkg-snapshot.json

now_ns() {
  date +%s%N
}

# --- quiet counts from the last busy moment ---------------------------------------------------

assert_exit 0 run_observe
pkg example-editor 1.2.4-1
touch -d '-40 seconds' "$dpkg_dir/status"
lock_line /var/lib/dpkg/lock-frontend >"$DS_SYSTEM_ROOT/proc/locks"
(sleep 1 && : >"$DS_SYSTEM_ROOT/proc/locks" && now_ns >"$DS_TEST_ROOT/released") &
releaser=$!
assert_exit 0 run_observe --settle-seconds 3 --wait-limit 60
finished=$(now_ns)
wait "$releaser"
# It sees the lock once a second: quiet starts at the last time it saw it held.
(((finished - $(<"$DS_TEST_ROOT/released")) >= 2000000000)) ||
  ds_fail "the observer went on less than --settle-seconds after dpkg let go of its lock"
assert_contains "$DS_STDOUT" "1 package changed since the last observation"

# --- a held lock: no limit -------------------------------------------------------------------

pkg example-editor 1.3.0-1
lock_line /var/lib/dpkg/lock-frontend >"$DS_SYSTEM_ROOT/proc/locks"
(sleep 2 && : >"$DS_SYSTEM_ROOT/proc/locks") &
releaser=$!
assert_exit 0 run_observe --wait-limit 1
wait "$releaser"
assert_contains "$DS_STDOUT" "1 package changed since the last observation"
assert_eq "1.3.0-1" "$(jq -r '.packages["example-editor"]' "$snapshot")"
# The other signs keep their limit.
: >"$dpkg_dir/updates/0001"
assert_exit 0 run_observe --wait-limit 0
assert_contains "$DS_STDOUT" "dpkg did not settle within 0 s (/var/lib/dpkg/updates holds unfinished work)"
rm -f -- "$dpkg_dir/updates/0001"

# --- the device of a lock: what stat says, or the superblock of its mount -----------------------

# btrfs: /proc/locks names the device of the superblock, which /proc/self/mountinfo has (in
# decimal), stat the one of the subvolume. Device and inode match: dpkg holds it, no limit.
mkdir -p "$DS_SYSTEM_ROOT/proc/self"
printf '36 25 0:255 / %s rw,relatime shared:1 - btrfs /dev/vda2 rw,subvol=/@\n' "$(realpath "$dpkg_dir")" \
  >"$DS_SYSTEM_ROOT/proc/self/mountinfo"
printf '1: POSIX  ADVISORY  WRITE 4242 00:ff:%s 0 EOF\n' "$(stat -c '%i' "$dpkg_dir/lock")" \
  >"$DS_SYSTEM_ROOT/proc/locks"
pkg example-editor 1.3.1-1
(sleep 5 && : >"$DS_SYSTEM_ROOT/proc/locks") &
releaser=$!
started=$SECONDS
assert_exit 0 run_observe --wait-limit 0
took=$((SECONDS - started))
wait "$releaser"
((took >= 5)) || ds_fail "a lock on the device of the superblock was not seen"
assert_contains "$DS_STDOUT" "1 package changed since the last observation"
rm -f -- "$DS_SYSTEM_ROOT/proc/self/mountinfo"

# Without the device of the superblock, a lock of the same inode on another anonymous device
# (tmpfs, another subvolume, FUSE) may be dpkg's or another file's: it keeps the observer
# waiting, but only up to the wait limit.
shm=/dev/shm
if [[ -d $shm && -w $shm && $(stat -c '%t' "$shm") == 0 ]]; then
  anonymous=$(mktemp "$shm/dotsteward-test-lock.XXXXXX")
  ds_defer rm -f -- "$anonymous"
  ln -sfn "$anonymous" "$dpkg_dir/lock"
  printf '1: FLOCK  ADVISORY  WRITE 4242 00:2a:%s 0 EOF\n' "$(stat -L -c '%i' "$dpkg_dir/lock")" \
    >"$DS_SYSTEM_ROOT/proc/locks"
  pkg example-editor 1.3.2-1
  assert_exit 0 timeout 30 "$agents_fw/cli/dotsteward" --instance "$agents_inst" observe --settle-seconds 0 \
    --wait-limit 1 </dev/null
  assert_contains "$DS_STDOUT" "dpkg did not settle within 1 s (/var/lib/dpkg/lock may be locked: a lock of its inode on another device)"
  : >"$DS_SYSTEM_ROOT/proc/locks"
  rm -f -- "$dpkg_dir/lock"
  : >"$dpkg_dir/lock"
  assert_exit 0 run_observe
  assert_contains "$DS_STDOUT" "1 package changed since the last observation"
else
  printf 'no tmpfs at %s: the anonymous device case is not checked here\n' "$shm" >&2
fi

# --- a snapshot that is no object ----------------------------------------------------------------

printf '[]\n' >"$snapshot"
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "the first observation: the installed packages are the baseline"
assert_json "$snapshot" '.packages["example-editor"] != null'
