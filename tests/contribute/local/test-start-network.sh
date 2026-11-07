# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# What `dotsteward contribute` counts as a failure of the network, through the
# fetch of `start`, the first network operation of a run. The words of a
# failed connection and the time limit make the operation again. Everything
# else stops at once, without a pause: a remote that refused access, in
# whatever words, and a failure on this machine, such as an ssh that does not
# exist. Unknown words count as no network failure: one attempt, as before
# there were pauses. start gives a network that stays down about a minute
# (nothing waits for it and it is safe to run again), unless
# DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS says otherwise.
# shellcheck source=tests/contribute/local/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/local/helpers.sh"

export DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS=30
export DS_FAKESSH_DROPS=$DS_TEST_ROOT/drops

setup_owner

# --- the words of a failed connection: made again --------------------------------------------------

slug=0
while IFS= read -r text; do
  slug=$((slug + 1))
  printf x >"$DS_FAKESSH_DROPS"
  DS_FAKESSH_DROP_TEXT=$text assert_exit 0 run_contribute start --slug "dropped-$slug"
  assert_contains "$DS_STDERR" "$text"
  assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot fetch main from origin; trying again in 1s" "$text"
done <<'TEXTS'
ssh: connect to host github.com port 22: Connection timed out
ssh: connect to host github.com port 22: Network is unreachable
ssh: Could not resolve hostname github.com: Temporary failure in name resolution
kex_exchange_identification: Connection closed by remote host
Connection reset by 192.0.2.1 port 22
client_loop: send disconnect: Broken pipe
TEXTS

# --- a remote that refused, in whatever words: one attempt --------------------------------------------

while IFS= read -r text; do
  printf x >"$DS_FAKESSH_DROPS"
  DS_FAKESSH_DROP_TEXT=$text assert_exit 1 run_contribute start --slug refused-run
  assert_contains "$DS_STDERR" "$text"
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: could not fetch main from origin" "$text"
  assert_not_contains "$DS_STDERR" "trying again" "$text"
done <<'TEXTS'
git@github.com: Permission denied (publickey).
ERROR: Permission to example-org/dotsteward.git denied to example-user.
ERROR: Repository not found.
Host key verification failed.
ERROR: Access denied: the repository is disabled
ERROR: You're using an RSA key with SHA-1, which is no longer allowed
remote: fatal: disk quota exceeded
TEXTS

# --- a failure on this machine: one attempt -------------------------------------------------------------

GIT_SSH_COMMAND=$DS_TEST_ROOT/no-such-ssh assert_exit 1 run_contribute start --slug refused-run
assert_contains "$DS_STDERR" "[dotsteward] ERROR: could not fetch main from origin"
assert_not_contains "$DS_STDERR" "trying again"

# --- the time limit: made again ------------------------------------------------------------------------

tools=$DS_TEST_ROOT/tools
mkdir -p "$tools"
real_timeout=$(command -v timeout)
cat >"$tools/timeout" <<EOF
#!$BASH
if [[ -e $DS_TEST_ROOT/timeout-once ]]; then
  rm -f -- "$DS_TEST_ROOT/timeout-once"
  exit 124
fi
exec "$real_timeout" "\$@"
EOF
chmod 0755 "$tools/timeout"
: >"$DS_TEST_ROOT/timeout-once"
PATH=$tools:$PATH assert_exit 0 run_contribute start --slug timed-out
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot fetch main from origin; trying again in 1s"

# --- the time start gives a network that stays down -------------------------------------------------

# A first pause of 100 s shows the limit: it is cut to what the limit leaves.
# The pauses cost no time.
cat >"$tools/sleep" <<EOF
#!$BASH
printf '%s\n' "\$1" >>"$DS_TEST_ROOT/sleep.log"
EOF
chmod 0755 "$tools/sleep"
start_slow() {
  PATH=$tools:$PATH DOTSTEWARD_CONTRIBUTE_POLL_SECONDS=100 run_contribute start --slug "$1"
}
printf x >"$DS_FAKESSH_DROPS"
unset DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS
assert_exit 0 start_slow default-limit
# The pause is what the limit of 60 s leaves after the first fetch, which takes
# a second or more on a loaded machine.
pause=$(<"$DS_TEST_ROOT/sleep.log")
((pause > 30 && pause <= 60)) || ds_fail "the pause under the limit of start: $pause"
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot fetch main from origin; trying again in ${pause}s"
printf x >"$DS_FAKESSH_DROPS"
export DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS=300
assert_exit 0 start_slow chosen-limit
assert_contains "$DS_STDERR" "[dotsteward] WARNING: cannot fetch main from origin; trying again in 100s"

assert_eq "" "$(temp_leftovers)" "temporary files left behind"
