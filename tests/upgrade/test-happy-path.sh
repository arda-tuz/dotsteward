# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# E1, the happy path on a terminal in tracked mode: one sudo window before all Nix work, the bridge
# before apt-get update, recovery, policy and the commit of the apt engine, then the writer, the
# gate, a local commit, self triggers, the rebuild, E2E, the publish and the report. Nothing but
# upgrade touches the remote. A second run has nothing left: no rebuild, no E2E, no second weekly
# Nix move. Reboot is said, never done.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

install_bridge
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
tool_stub codex 'printf "codex-cli 1.0.0\n"'
tool_stub uname 'case "$1" in -r) printf "7.0.0-38-generic\n";; *) printf "Linux\n";; esac'
tool_stub fwupdmgr 'exit 2'
ds_dpkg_installed example-tracked 1.0
NEWEST='"newest_kernel": {"abi": "7.0.0-42", "base": "generic", "release": "7.0.0-42-generic", "nvidia": false, "prebuilt": false, "driver_version": null, "planned": false}'

apt_answer commit '{"status": "committed", "committed": true,
  "changes": {"install": [], "upgrade": [{"name": "example-tracked", "from": "1.0", "to": "1.1"}], "remove": [], "downgrade": []},
  "items": [], "gated": {"decision": "no-move"}, "applicable": true, "log": null, '"$NEWEST"'}'
move flake_inputs.nixpkgs 26.05-new channel
move agent_tools.codex.linux 2.0.0 download

before_remote=$(remote_oid)
assert_exit 0 on_terminal 'Update these too=n' -- --tracked --accept install:example-accepted
output=$DS_STDOUT

assert_order '^sudo -v' '^sudo -n( |.*)true|^sudo -n .*recover' '^apt recover' '^apt policy' '^bridge ' \
  '^sudo -n apt-get .*update' '^apt commit' '^sudo -k' '^pins latest' '^pins .*apply' '^static ' '^claude update' \
  '^rebuild .*root=.*/upgrade/work' '^e2e .*root=.*/upgrade/work' "^rebuild .*root=$up_inst\$"
work_gone
assert_no_step "^pins .*root=$up_inst\$"

assert_no_step '^(sudo .*)?reboot'
assert_no_step 'autoremove'
assert_no_step 'do-release-upgrade'

# The tracked set: packageNames, apt and track of the active deb components only.
assert_contains "$(steps '^apt commit')" '"mode":"tracked"'
assert_contains "$(steps '^apt commit')" '"tracked":["example-tracked","example-tracked-lib","example-tracked-too"]'
assert_contains "$(steps '^apt commit')" '"accept":["install:example-accepted"]'
assert_eq "bridge /etc/dotsteward/apt-bridge.d /var/lib/dotsteward/apt-bridge" \
  "$(steps '^bridge ' | sed "s|$DS_SYSTEM_ROOT||g")"

# The week was due: nothing is skipped on the first run.
assert_not_contains "$(steps '^pins .*apply')" "--skip"

# The local commit passed the real gate and went out through the real txn publish.
assert_eq "chore: update pinned tool versions" "$(git -C "$up_inst" log -1 --format=%s HEAD -- versions.lock.json)"
assert_eq "$(remote_oid)" "$(git -C "$up_inst" rev-parse HEAD)"
[[ $(remote_oid) != "$before_remote" ]] || ds_fail "nothing was published"
assert_eq "" "$(git -C "$up_inst" status --porcelain)" "the checkout stays clean"
assert_json "$up_inst/versions.lock.json" '."flake_inputs.nixpkgs" == "26.05-new"'
assert_contains "$(git -C "$up_inst" log --format=%s)" "hosts"

# The report.
last_report '.command == "upgrade" and .status == "ok" and .exit_code == 0'
last_report '.data.mode == "tracked" and .data.profile == "workstation"'
assert_eq ok "$(step_status apt-commit)"
assert_eq ok "$(step_status publish)"

# Only said: the machine runs an older kernel than it has, by the word of the engine.
assert_contains "$output" "7.0.0-42-generic"
assert_contains "$output" "eboot"
review_json '[.items[] | select(.code == "reboot-required")] | length == 1'
review_json '.exit_code == 0'
last_report '.data.newest_kernel.release == "7.0.0-42-generic"'

apt_answer commit "$NOTHING_CHANGED"

# Without a sudo window this run, the plan of the engine still says what a reboot starts, and the
# module the kernel lacks waits for a person.
apt_answer plan '{"status": "nothing", "changes": {}, "applicable": true, '"$NEWEST"', "items": [{"code": "module-missing", "pending": true, "kernel": "7.0.0-42-generic", "message": "the newest kernel has no nvidia module"}, {"code": "phased-waiting", "pending": false, "packages": ["example-lib"]}]}'
assert_exit 3 upgrade --tracked
review_json '[.items[] | select(.code == "module-missing" and .kernel == "7.0.0-42-generic")] | length == 1'
review_json '[.items[] | select(.code == "phased-waiting")] | length == 0'
review_json '[.items[] | select(.code == "reboot-required")] | length == 1'
apt_answer plan "$NOTHING_CHANGED"

# The analysis is local: review.json names numbers and the path.
assert_file_mode "$DOTSTEWARD_STATE_ROOT/upgrade/analysis.json" 600
assert_json "$DOTSTEWARD_STATE_ROOT/upgrade/analysis.json" '.schema_version == 1 and .channels.apt.available == true'

# --- a second run converged ----------------------------------------------------------------------
clear_log
oid=$(remote_oid)
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_order '^sudo -v' '^apt commit' '^sudo -k' '^pins .*apply'
assert_contains "$(steps '^pins .*apply')" "--skip flake_inputs.*"
assert_no_step '^rebuild '
assert_no_step '^e2e '
assert_eq "$oid" "$(remote_oid)"
assert_eq skipped "$(jq -r '[.steps[] | select(.name == "e2e") | .detail] | first | split(":")[0]' "$(newest_report)")"

# A tracked package moved: the E2E key changed, E2E runs again on the same generation.
clear_log
ds_dpkg_installed example-tracked 1.2
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_no_step '^rebuild '
assert_order '^e2e '
