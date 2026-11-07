# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Inside the container: what the owner sees on a terminal, with the real sudo (a password), apt and
# dpkg. Git, the gate and the publish are real as well; Nix and the rebuild are the fakes of
# tests/upgrade, since a container has no Home Manager.
# shellcheck source=tests/container/scenarios/lib.sh
source "$DS_REPO_ROOT/tests/container/scenarios/lib.sh"
# shellcheck source=tests/apt-worlds/helpers.sh
source "$DS_REPO_ROOT/tests/apt-worlds/helpers.sh"

apt --version | head -n 1
UP_REAL_APT=machine
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"
unset DOTSTEWARD_SYSTEM_ROOT
tool_stub claude
tool_stub fwupdmgr 'exit 2'
modinfo_stub
TYPED='for tester:=container-test'
MODULE=linux-modules-nvidia-595-open

# The sudo of the setup is open: a run starts from a closed one.
closed() {
  sudo -k
}

# --- a same-series kernel and module, on a machine with the bridge: no question ------------------
sudo_open
world_install same-string
sudo -n mkdir -p /usr/local/lib/dotsteward
printf 'printf "bridge %%s\\n" "$*" >>"%s"\n' "$UP_LOG" | sudo -n tee /usr/local/lib/dotsteward/apt-bridge.sh >/dev/null
closed
assert_exit 0 on_terminal "$TYPED" -- --tracked
output=$DS_STDOUT
assert_order '^sudo -v' '^bridge /etc/dotsteward/apt-bridge.d /var/lib/dotsteward/apt-bridge' '^sudo -n apt-get .*update' '^sudo -k' '^rebuild|^e2e'
assert_eq "$K44" "$(version_of linux-generic-hwe-24.04)"
assert_eq "$K44" "$(version_of "$MODULE-generic-hwe-24.04")"
assert_eq "$K42" "$(version_of linux-image-7.0.0-42-generic)" "the kernel before stays"
pin_matches_dpkg
candidates_stay
assert_contains "$output" "eboot"
assert_exit 1 sudo -n true
sudo_open
sudo -n rm -f /usr/local/lib/dotsteward/apt-bridge.sh
closed

# --- a new series is said; nothing moves it -------------------------------------------------------
sudo_open
world_install new-series
before=$(gated_state)
closed
clear_log
assert_exit 0 on_terminal "$TYPED" -- --tracked
assert_contains "$DS_STDOUT" "dotsteward upgrade --accept series:kernel=7.4"
assert_eq "$before" "$(gated_state)"

# --- tracked, then the offer -------------------------------------------------------------------------
sudo_open
world_install tracked
closed
clear_log
assert_exit 0 on_terminal "$TYPED" 'Update these too=n' -- --tracked
assert_eq "2.0-1" "$(version_of example-tracked)"
assert_eq "1.0-1" "$(version_of example-other)" "the offer was declined"

clear_log
assert_exit 0 on_terminal "$TYPED" 'Update these too=y' "$TYPED" -- --tracked
assert_eq "2.0-1" "$(version_of example-other)" "the offer was taken"
assert_contains "$(steps '^sudo -k' | wc -l)" "2"
assert_order '^sudo -k' '^sudo -v' '^sudo -k' '^e2e '

# --- everything: no second question -------------------------------------------------------------------
sudo_open
world_install tracked
closed
clear_log
assert_exit 0 on_terminal 'Update what=2' "$TYPED" --
assert_eq "2.0-1" "$(version_of example-other)"
assert_not_contains "$DS_STDOUT" "Update these too"

# --- without a terminal nothing moves and sudo is never touched ----------------------------------------
sudo_open
world_install tracked
closed
clear_log
assert_exit 3 upgrade
assert_eq "1.0-1" "$(version_of example-tracked)"
assert_no_step '^sudo'
review_json '[.items[] | select(.code == "sudo-required")] | length == 1'

# --- dpkg left half way: the terminal run recovers first -------------------------------------------------
sudo_open
half=$(find /srv/world -name 'example-tracked_2.0-1*.deb' -print -quit)
[[ -n $half ]] || ds_fail "the world has no package to leave half way"
sudo -n dpkg --unpack "$half" >/dev/null
[[ -n $(sudo -n dpkg --audit) ]] || ds_fail "dpkg should have something to say now"
closed
clear_log
assert_exit 0 on_terminal "$TYPED" 'Update these too=n' -- --tracked
assert_order '^sudo -v' '^sudo -n .*recover' '^sudo -n apt-get .*update'
sudo_open
audit_clean
closed
assert_eq "2.0-1" "$(version_of example-tracked)"

# --- sudo that closes at once: asked once more, then the rest of the window waits ---------------------------
sudo_open
printf 'Defaults:tester timestamp_timeout=0\n' | sudo -n install -m 0440 /dev/stdin /etc/sudoers.d/zz-no-timestamp
clear_log
assert_exit 3 on_terminal "$TYPED" "$TYPED" 'Update these too=n' -- --tracked
review_json '[.items[] | select(.code == "sudo-required")] | length == 1'
assert_no_step '^sudo -n apt-get .*update'
assert_order '^e2e |^pins '
printf 'container-test\n' | sudo -S -p '' rm -f /etc/sudoers.d/zz-no-timestamp
