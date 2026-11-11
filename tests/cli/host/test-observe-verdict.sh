# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs and child scripts are single-quoted on purpose
# When a verdict of `dotsteward observe` stands, and how long red stays red.
# - dpkg moves while the checks run (the owner starts apt): the verdict is dropped, with no
#   red, no notification and nothing recorded for it, and the observer settles again and
#   checks once more.
# - Red is cleared by the next green check: a later run of the observer checks the red
#   components again even when no package changed, and a green full `dotsteward e2e`
#   verifies the deb components it checked (a red one it checked stays red).
# - The instance lock covers the comparison, the checks and the local record only: the
#   push of the state branch runs after it is let go, so a slow network keeps no `upgrade`
#   out.
# - A record the remote refuses does not undo the verdict: the next trigger neither checks
#   the change again nor notifies a second time.
# shellcheck source=tests/cli/host/observe-helpers.sh
source "$DS_REPO_ROOT/tests/cli/host/observe-helpers.sh"

add_component example-editor deb '{"packageNames": ["example-editor"]}'
cat <<'SH' | add_e2e_hook example-editor editor-opens main
printf 'editor-opens\n' >>"$E2E_HOOK_LOG"
if [[ -e $E2E_DURING ]]; then
  # The owner starts apt while the check runs: dpkg writes its status file, the editor is
  # half configured for a moment and does not start.
  bash "$E2E_DURING"
  rm -f -- "$E2E_DURING"
  exit 1
fi
[[ ! -e $E2E_BROKEN ]]
SH
export E2E_HOOK_LOG=$e2e_hook_log E2E_DURING=$DS_TEST_ROOT/during.sh E2E_BROKEN=$DS_TEST_ROOT/broken
publish_instance "chore: one component"
pkg libexample1 1.0-1
pkg example-editor 1.2.3-1 "Depends=libexample1"
name_machine laptop
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "the first observation"

# --- dpkg moves during the checks: no verdict, no notification, a second round ---------------

cat >"$E2E_DURING" <<SH
printf 'Package: late-package\\nStatus: install ok installed\\nVersion: 1.0\\nArchitecture: amd64\\n' \\
  >"$DS_STUB_STATE/dpkg/installed/late-package"
{ printf '\\n'; cat "$DS_STUB_STATE/dpkg/installed/late-package"; } >>"$dpkg_dir/status"
SH
pkg libexample1 1.1-1 "Depends="
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "dpkg changed during the checks: the verdict is dropped"
assert_not_contains "$DS_STDOUT" "red at"
assert_contains "$DS_STDOUT" "example-editor: verified at 1.2.3-1 (changed: libexample1)"
assert_eq $'editor-opens\neditor-opens' "$(hooks_ran)"
assert_eq "" "$(ds_calls_of notify-send)"
assert_eq '"verified"' "$(shown '.state.components["example-editor"].status')"
assert_eq "1.0" "$(jq -r '.packages["late-package"]' "$DOTSTEWARD_STATE_ROOT/observe/dpkg-snapshot.json")"

# --- red, then fixed without a package change: the next run of the observer checks again ----

: >"$E2E_BROKEN"
pkg libexample1 1.2-1 "Depends="
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "example-editor: red at 1.2.3-1, last verified 1.2.3-1 (changed: libexample1)"
assert_call_count 1 notify-send
assert_eq "editor-opens" "$(hooks_ran)"
# Still broken: checked again, red again, but the owner was told once.
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "no package changed since the last observation"
assert_contains "$DS_STDOUT" "example-editor: red at 1.2.3-1, last verified 1.2.3-1 (red before)"
assert_call_count 1 notify-send
assert_eq "editor-opens" "$(hooks_ran)"
# The fix needs no package (a source list, the network): green again.
rm -f -- "$E2E_BROKEN"
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "example-editor: verified at 1.2.3-1 (red before)"
assert_eq '"verified"' "$(shown '.state.components["example-editor"].status')"
# Green and nothing changed: nothing to check.
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "no package changed since the last observation"
assert_eq "" "$(hooks_ran)"

# --- a full E2E run clears red, and keeps red what it found red ------------------------------

: >"$E2E_BROKEN"
pkg libexample1 1.3-1 "Depends="
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "example-editor: red at 1.2.3-1"
assert_exit 1 run_e2e --keep-going
assert_exit 0 run_state record
assert_eq '"red"' "$(shown '.state.components["example-editor"].status')"
rm -f -- "$E2E_BROKEN"
assert_exit 0 run_e2e
assert_exit 0 run_state record
assert_json - '.status == "verified" and .version == "1.2.3-1" and .last_verified.version == "1.2.3-1"' \
  <<<"$(shown '.state.components["example-editor"]')"
hooks_ran >/dev/null
# A run of some components (as the observer runs it) leaves the verdict to its caller.
: >"$E2E_BROKEN"
assert_exit 1 run_e2e --component example-editor
assert_exit 0 run_state record
assert_eq '"verified"' "$(shown '.state.components["example-editor"].status')"
rm -f -- "$E2E_BROKEN"
hooks_ran >/dev/null

# --- the push runs after the instance lock is let go -----------------------------------------

lock_status() {
  PYTHONPATH=$agents_fw/cli/python PYTHONDONTWRITEBYTECODE=1 python3 -s -P -m dotsteward_cli.internal lock status \
    --state-root "$DOTSTEWARD_STATE_ROOT"
}
pkg libexample1 1.4-1 "Depends="
out=$DS_TEST_ROOT/slow-push.out
DS_FAKESSH_SLEEP=6 "$agents_fw/cli/dotsteward" --instance "$agents_inst" observe --settle-seconds 0 \
  </dev/null >"$out" 2>&1 &
observer=$!
tries=0
until grep -q "recorded the state of laptop" "$out"; do
  tries=$((tries + 1))
  ((tries < 1500)) || ds_fail "the observer recorded nothing: $(<"$out")"
  sleep 0.02
done
assert_eq 'false' "$(lock_status | jq -r .held)" "the observer holds the instance lock while it pushes"
wait "$observer"
assert_contains "$(<"$out")" "published state/laptop"
assert_eq "$(state_tip)" "$(git -C "$e2e_bare" rev-parse refs/heads/state/laptop)"
hooks_ran >/dev/null

# --- a refused record: the change is not checked again and nobody is notified twice ----------

: >"$DS_CALL_LOG"
: >"$E2E_BROKEN"
cat >"$e2e_bare/hooks/pre-receive" <<'SH'
#!/usr/bin/env bash
echo "refusing: no space left on device" >&2
exit 1
SH
chmod +x "$e2e_bare/hooks/pre-receive"
pkg libexample1 1.5-1 "Depends="
assert_exit 1 run_observe
assert_contains "$DS_STDOUT" "example-editor: red at 1.2.3-1"
assert_contains "$DS_STDERR" "refused"
assert_call_count 1 notify-send
assert_eq "1.5-1" "$(jq -r '.packages.libexample1' "$DOTSTEWARD_STATE_ROOT/observe/dpkg-snapshot.json")"
assert_exit 1 run_observe
assert_contains "$DS_STDOUT" "no package changed since the last observation"
assert_call_count 1 notify-send
rm -f -- "$e2e_bare/hooks/pre-receive" "$E2E_BROKEN"
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "example-editor: verified at 1.2.3-1 (red before)"
assert_contains "$DS_STDOUT" "published state/laptop"
