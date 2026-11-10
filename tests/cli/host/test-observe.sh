# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# `dotsteward observe`: the owner changes system packages outside dotsteward (an apt
# upgrade in a terminal) and the observer, started by the path unit on the dpkg status
# file, notices it. Its first run takes the installed packages as the baseline. Later it
# compares them with the last observation: when nothing changed it does nothing; when
# something changed it checks the tracked deb components whose packages changed or whose
# dependency closure (Depends and Pre-Depends, alternatives, virtual packages) holds a
# changed package, with their E2E checks alone, records the result on the state branch
# through the state writer and names each such component. A red one gets a desktop
# notification, keeps its last verified version apart from the installed one and stays
# red for a plain `state record`. The observer never changes a package: what the owner
# installed stays installed. Without a network the record waits, and the next run sends it.
# shellcheck source=tests/cli/host/observe-helpers.sh
source "$DS_REPO_ROOT/tests/cli/host/observe-helpers.sh"

# A deb component whose E2E check fails for the version 2.0.0-1, one that depends on a
# virtual package and on an alternative, one without E2E checks, and one of another method.
add_component example-shell external '{}'
add_component example-editor deb '{"packageNames": ["example-editor"]}'
add_component example-viewer deb '{"packageNames": ["example-viewer"]}'
add_component example-tool deb '{"packageNames": ["example-tool"]}'
cat <<'SH' | add_e2e_hook example-editor editor-opens main
printf 'editor-opens\n' >>"$E2E_HOOK_LOG"
[[ $(dpkg-query -W -f '${Version}' example-editor) != 2.0.0-1 ]]
SH
cat <<'SH' | add_e2e_hook example-viewer viewer-opens main
printf 'viewer-opens\n' >>"$E2E_HOOK_LOG"
SH
export E2E_HOOK_LOG=$e2e_hook_log
publish_instance "chore: three components"

pkg libexample-core 1.0-1
pkg libexample1 1.0-1 "Depends=libexample-core (>= 1.0)"
pkg example-editor 1.2.3-1 "Depends=libexample1 (>= 1.0), libc-example"
pkg libc-example 2.39-1
pkg example-render-impl 3.0-1 "Provides=example-render"
pkg libtool-example 1.0-1
pkg example-viewer 5.0-1 "Pre-Depends=libtool-example:any" "Depends=libmissing-example | example-render (>= 2)"
pkg example-tool 0.5-1 "Depends=libexample-core"
pkg unrelated-package 9.9

head=$(git -C "$agents_inst" rev-parse HEAD)
main_before=$(git -C "$e2e_bare" rev-parse refs/heads/main)

checkout_untouched() {
  assert_eq "$head" "$(git -C "$agents_inst" rev-parse HEAD)" "the checkout moved"
  assert_eq "" "$(git -C "$agents_inst" status --porcelain --untracked-files=normal)" "the checkout changed"
  assert_eq "$main_before" "$(git -C "$e2e_bare" rev-parse refs/heads/main)" "main of the remote moved"
}

# The observer never changes a package of the owner.
nothing_installed() {
  assert_eq "" "$(ds_calls_of dpkg | grep -v -e '^dpkg --audit$' -e '^dpkg --print-architecture$' || true)" \
    "the observer ran dpkg for more than reading"
  assert_eq "" "$(ds_calls_of sudo)" "the observer ran sudo"
}

# --- a machine without a name: nothing to record ----------------------------------------

assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "this machine has no name yet"
assert_eq "" "$(state_tip)"
assert_eq "" "$(hooks_ran)"

# --- the first run: the baseline, no checks and no notification ------------------------

name_machine laptop
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "the first observation: the installed packages are the baseline"
assert_contains "$DS_STDOUT" "recorded the state of laptop on state/laptop"
assert_contains "$DS_STDOUT" "published state/laptop"
first=$(state_tip)
[[ -n $first ]] || ds_fail "the first observation recorded nothing"
assert_eq "$first" "$(git -C "$e2e_bare" rev-parse refs/heads/state/laptop)"
assert_eq '"observe"' "$(shown '.state.recorded_by')"
assert_eq '{"status":"installed","packages":{"example-editor":"1.2.3-1"}}' \
  "$(shown '.state.components["example-editor"]')"
assert_eq "" "$(hooks_ran)"
assert_eq "" "$(ds_calls_of notify-send)"
assert_file_mode "$DOTSTEWARD_STATE_ROOT/observe/dpkg-snapshot.json" 600
checkout_untouched

# --- nothing changed: nothing to do -----------------------------------------------------

assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "no package changed since the last observation"
assert_eq "$first" "$(state_tip)"
assert_eq "" "$(hooks_ran)"

# --- a change no tracked component depends on: no check ---------------------------------

pkg unrelated-package 10.0
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "1 package changed since the last observation"
assert_contains "$DS_STDOUT" "no tracked component depends on what changed"
assert_eq "" "$(hooks_ran)"
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "no package changed since the last observation"

# --- a library two levels down the closure of one component: only that one is checked ----

pkg libexample-core 1.1-1
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "example-editor: verified at 1.2.3-1 (changed: libexample-core)"
assert_not_contains "$DS_STDOUT" "example-viewer:"
assert_eq "editor-opens" "$(hooks_ran)"
assert_json - '. == {status: "verified", version: "1.2.3-1", packages: {"example-editor": "1.2.3-1"}}' \
  <<<"$(shown '.state.components["example-editor"] | del(.last_verified)')"
assert_eq '"1.2.3-1"' "$(shown '.state.components["example-editor"].last_verified.version')"
assert_eq '"installed"' "$(shown '.state.components["example-viewer"].status')"
assert_eq '"observe"' "$(shown '.state.recorded_by')"
assert_eq "" "$(ds_calls_of notify-send)"
# A component without E2E checks is named, but nothing verified it.
assert_contains "$DS_STDOUT" "example-tool: no E2E checks at 0.5-1 (changed: libexample-core)"
assert_eq '"installed"' "$(shown '.state.components["example-tool"].status')"
assert_eq 'null' "$(shown '.state.components["example-tool"].last_verified')"
# A check of some components is no E2E run of the machine: the record of E2E stays.
[[ ! -e $DOTSTEWARD_STATE_ROOT/update/e2e.json ]] || ds_fail "the observer wrote the record of a full E2E run"

# --- a virtual package and an alternative: the provider of example-render ---------------

pkg example-render-impl 3.1-1 "Provides=example-render"
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "example-viewer: verified at 5.0-1 (changed: example-render-impl)"
assert_not_contains "$DS_STDOUT" "example-editor:"
assert_eq "viewer-opens" "$(hooks_ran)"

# An architecture qualifier names the package all the same.
pkg libtool-example 1.1-1
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "example-viewer: verified at 5.0-1 (changed: libtool-example)"
assert_eq "viewer-opens" "$(hooks_ran)"

# --- the owner upgrades a tracked package to a broken version: red, and it stays ---------

pkg example-editor 2.0.0-1 "Depends=libexample1 (>= 1.0), libc-example"
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "example-editor: red at 2.0.0-1, last verified 1.2.3-1 (changed: example-editor)"
assert_eq "editor-opens" "$(hooks_ran)"
assert_json - '.status == "red" and .version == "2.0.0-1" and .packages == {"example-editor": "2.0.0-1"}
  and .last_verified.version == "1.2.3-1"' <<<"$(shown '.state.components["example-editor"]')"
assert_call_count 1 notify-send
assert_contains "$(ds_calls_of notify-send)" "example-editor"
assert_contains "$(ds_calls_of notify-send)" "2.0.0-1"
# The owner's version stays: the observer neither downgrades nor holds it.
assert_eq "2.0.0-1" "$(ds_dpkg_version example-editor)"
nothing_installed
# A plain record of the state keeps what the last check said.
assert_exit 0 run_state record
assert_eq '"red"' "$(shown '.state.components["example-editor"].status')"
assert_eq '"1.2.3-1"' "$(shown '.state.components["example-editor"].last_verified.version')"

# A version nobody checked yet is unverified until the next observation checks it.
ds_dpkg_installed example-editor 2.0.1-1 amd64 "Depends=libexample1 (>= 1.0), libc-example"
assert_exit 0 run_state record
assert_eq '"unverified"' "$(shown '.state.components["example-editor"].status')"

# The fixed version: verified again.
pkg example-editor 2.0.1-1 "Depends=libexample1 (>= 1.0), libc-example"
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "example-editor: verified at 2.0.1-1 (changed: example-editor)"
assert_eq "editor-opens" "$(hooks_ran)"
assert_json - '.status == "verified" and .version == "2.0.1-1" and .last_verified.version == "2.0.1-1"' \
  <<<"$(shown '.state.components["example-editor"]')"
assert_call_count 1 notify-send

# --- the owner removes a tracked package: named as missing, nothing reinstalled ---------

unpkg example-viewer
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "example-viewer: missing (changed: example-viewer)"
assert_eq "" "$(hooks_ran)"
assert_eq '"missing"' "$(shown '.state.components["example-viewer"].status')"
assert_eq "" "$(ds_dpkg_version example-viewer)"
nothing_installed
pkg example-viewer 5.0-1 "Pre-Depends=libtool-example:any" "Depends=libmissing-example | example-render (>= 2)"
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "example-viewer: verified at 5.0-1 (changed: example-viewer)"
assert_eq "viewer-opens" "$(hooks_ran)"

# --- checks that give no result: the state is recorded, and the next run checks again -----

hook=$agents_inst/components/example-editor/editor-opens.sh
mv -- "$hook" "$hook.away"
pkg libexample1 1.1-1 "Depends=libexample-core (>= 1.0)"
assert_exit 1 run_observe
assert_contains "$DS_STDERR" "the E2E checks of example-editor gave no result"
assert_call_count 1 notify-send
assert_eq '"observe"' "$(shown '.state.recorded_by')"
mv -- "$hook.away" "$hook"
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "example-editor: verified at 2.0.1-1 (changed: libexample1)"
assert_eq "editor-opens" "$(hooks_ran)"

# --- no network: the record waits, and the next run sends it ----------------------------

pkg libc-example 2.40-1
before=$(git -C "$e2e_bare" rev-parse refs/heads/state/laptop)
assert_exit 6 env DS_FAKESSH_FAIL=1 "$agents_fw/cli/dotsteward" --instance "$agents_inst" observe \
  --settle-seconds 0 </dev/null
assert_contains "$DS_STDOUT" "example-editor: verified at 2.0.1-1 (changed: libc-example)"
assert_contains "$DS_STDERR" "state/laptop waits: no network or no login"
assert_eq "$before" "$(git -C "$e2e_bare" rev-parse refs/heads/state/laptop)" "an offline record reached the remote"
assert_eq 'true' "$(shown '.queued')"
# Nothing changed since, and the queue goes out.
assert_exit 0 run_observe
assert_contains "$DS_STDOUT" "no package changed since the last observation"
assert_contains "$DS_STDOUT" "published state/laptop"
assert_eq "$(state_tip)" "$(git -C "$e2e_bare" rev-parse refs/heads/state/laptop)"
assert_eq 'false' "$(shown '.queued')"
checkout_untouched

# --- the state branch stays out of the checkout's way -----------------------------------

assert_exit 0 run_e2e
