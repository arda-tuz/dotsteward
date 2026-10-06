# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Phase hooks of `install` (SPEC 3.4, 8.4, D10): after the deb transaction
# the systemInstall, postInstall and forbid hooks run in that order; within
# a list early before main before late, then in [components] order, then in
# declaration order. Only hooks of components active in the profile and
# whose own profiles include it run. Hooks get the hook environment; a
# failing hook stops the phase with "component <name> hook <hook> failed
# (exit N)". --check-only runs only the forbid hooks, with
# DOTSTEWARD_CHECK_ONLY=1. Script paths of a manifest mirror resolve
# <instance>/ and <dotsteward>/. A real manifest renders every hook script
# as a Nix store path (<store>/NAME in the mirror): without --generation,
# install builds the generation (rebuild --build-only, after the preflight
# gate) and runs the built manifest's hooks; --check-only, which writes
# nothing, reads the active generation instead.
# shellcheck source=tests/cli/methods/helpers.sh
source "$DS_REPO_ROOT/tests/cli/methods/helpers.sh"

ds_use_stubs sudo curl
none='{"command": null, "versionArgv": null, "minimum": null}'
add_component example-term external "$none"
add_component example-app external "$none"
add_component alpha external "$none" '["workstation"]'
order=$DS_TEST_ROOT/order

record() {
  printf 'printf "%%s\\n" %q >>%q\n' "$1" "$order"
}
record "app forbid" | add_hook forbid example-app forbid
record "app post main" | add_hook post_install example-app post-main
record "app post early" | add_hook post_install example-app post-early early
record "term post late" | add_hook post_install example-term post-late late
record "term post main" | add_hook post_install example-term post-main
record "app system" | add_hook system_install example-app system
record "term system workstation only" | add_hook system_install example-term system-ws main '["workstation"]'
record "term system fresh" | add_hook system_install example-term system-fresh main '["fresh"]'
record "alpha inactive" | add_hook post_install alpha post
add_hook post_install example-app env <<EOF
env | grep -E '^DOTSTEWARD_(ASSUME_YES|CHECK_ONLY|COMPONENT|INSTANCE|LIB|PLATFORM|PROFILE|PROFILE_MODE|STATE_ROOT)=' | LC_ALL=C sort >'$DS_TEST_ROOT/hook-env'
source "\$DOTSTEWARD_LIB/lib.sh"
log "hook says hello"
EOF

assert_exit 0 run_install --profile fresh
assert_eq "term system fresh
app system
app post early
term post main
app post main
term post late
app forbid" "$(<"$order")"
assert_contains "$DS_STDOUT" "[dotsteward] hook says hello"
assert_eq "DOTSTEWARD_ASSUME_YES=0
DOTSTEWARD_CHECK_ONLY=0
DOTSTEWARD_COMPONENT=example-app
DOTSTEWARD_INSTANCE=$methods_inst
DOTSTEWARD_LIB=$methods_fw/cli/lib
DOTSTEWARD_PLATFORM=linux
DOTSTEWARD_PROFILE=fresh
DOTSTEWARD_PROFILE_MODE=fresh
DOTSTEWARD_STATE_ROOT=$DOTSTEWARD_STATE_ROOT" "$(<"$DS_TEST_ROOT/hook-env")"
assert_calls "preflight --read-only --json --profile fresh"

# --check-only: only the forbid hooks, told they check.
rm -f "$order"
assert_exit 0 run_install --profile fresh --check-only
assert_eq "app forbid" "$(<"$order")"
add_hook forbid example-term check-env <<EOF
printf '%s\n' "\$DOTSTEWARD_CHECK_ONLY" >'$DS_TEST_ROOT/check-only'
EOF
assert_exit 0 run_install --profile fresh --check-only
assert_eq "1" "$(<"$DS_TEST_ROOT/check-only")"

# A failing hook stops the phase.
add_hook post_install example-term fails <<'EOF'
echo "post-install output"
exit 7
EOF
rm -f "$order"
assert_exit 1 run_install --profile fresh
assert_eq "[dotsteward] ERROR: component example-term hook fails failed (exit 7)" "$DS_STDERR"
assert_contains "$DS_STDOUT" "post-install output"
assert_eq "term system fresh
app system
app post early
term post main" "$(<"$order")"
manifest_edit '.hooks.post_install |= map(select(.name != "fails"))'

# A failing forbid hook in --check-only: fail-fast, or recorded with --json.
add_hook forbid example-app guard <<'EOF'
echo "unexpected autostart entry" >&2
exit 1
EOF
assert_exit 1 run_install --profile fresh --check-only
assert_eq "unexpected autostart entry
[dotsteward] ERROR: component example-app hook guard failed (exit 1)" "$DS_STDERR"
assert_exit 1 run_install --profile fresh --check-only --json
assert_json - '.result == "failed" and .hooks == [
  {"component": "example-term", "name": "check-env", "list": "forbid", "status": "passed", "exit_code": 0},
  {"component": "example-app", "name": "forbid", "list": "forbid", "status": "passed", "exit_code": 0},
  {"component": "example-app", "name": "guard", "list": "forbid", "status": "failed", "exit_code": 1}
]' <<<"$DS_STDOUT"
manifest_edit '.hooks.forbid |= map(select(.name != "guard"))'

# Script paths: <dotsteward>/ is the framework root, a <store>/ path runs
# from a built generation, a script must be an executable file.
mkdir -p "$methods_fw/tests-hooks"
printf '#!%s\ntouch %q\n' "$BASH" "$DS_TEST_ROOT/framework-hook-ran" >"$methods_fw/tests-hooks/hook.sh"
chmod 0755 "$methods_fw/tests-hooks/hook.sh"
manifest_edit '.hooks.forbid += [{component: "example-app", name: "framework", phase: "main", profiles: null, script: "<dotsteward>/tests-hooks/hook.sh"}]'
assert_exit 0 run_install --profile fresh
[[ -e $DS_TEST_ROOT/framework-hook-ran ]] || ds_fail "the <dotsteward>/ hook did not run"

# A <store>/ hook (what a real manifest carries): install builds the
# generation once the preflight gate passed and runs the hooks of the built
# manifest, whose script paths are absolute.
mkdir -p "$methods_store"
cat >"$methods_store/hook.sh" <<EOF
#!$BASH
printf '%s\n' "store forbid \$DOTSTEWARD_CHECK_ONLY" >>'$order'
EOF
chmod 0755 "$methods_store/hook.sh"
manifest_edit '.hooks.forbid += [{component: "example-app", name: "stored", phase: "main", profiles: null, script: "<store>/hook.sh"}]'
rm -f "$order"
: >"$DS_CALL_LOG"
assert_exit 0 run_install --profile fresh
assert_calls "preflight --read-only --json --profile fresh" "rebuild --profile fresh --build-only"
assert_eq "term system fresh
app system
app post early
term post main
app post main
term post late
app forbid
store forbid 0" "$(<"$order")"
assert_eq "$methods_generation" "$(<"$DOTSTEWARD_STATE_ROOT/current/last-built-activation")"

# The preflight gate stops before the build; a failing build stops the
# phase with its status before any hook or package step.
preflight_exit 3
rm -f "$order"
: >"$DS_CALL_LOG"
assert_exit 3 run_install --profile fresh
assert_calls "preflight --read-only --json --profile fresh"
[[ ! -e $order ]] || ds_fail "a hook ran after the preflight gate stopped the phase"
preflight_exit 0
rebuild_exit 4
: >"$DS_CALL_LOG"
assert_exit 4 run_install --profile fresh
assert_calls "preflight --read-only --json --profile fresh" "rebuild --profile fresh --build-only"
[[ ! -e $order ]] || ds_fail "a hook ran after the build failed"
rm -f "$DS_TEST_ROOT/rebuild-status"

# --check-only builds nothing: the forbid hooks come from the active
# generation; without one it refuses.
: >"$DS_CALL_LOG"
assert_exit 1 run_install --profile fresh --check-only
assert_eq "[dotsteward] ERROR: component example-app hook stored: <store>/hook.sh is a Nix store path and no Home Manager generation is active; switch to a generation (dotsteward rebuild --profile fresh --switch) or pass --generation with a built generation" "$DS_STDERR"
assert_calls
hm_profile=$HOME/.local/state/nix/profiles/home-manager
mkdir -p "$(dirname "$hm_profile")"
ln -sfn "$methods_generation" "$hm_profile"
rm -f "$order"
assert_exit 0 run_install --profile fresh --check-only
assert_eq "app forbid
store forbid 1" "$(<"$order")"
assert_calls
rm -f "$hm_profile"
manifest_edit '.hooks.forbid |= map(select(.name != "stored"))'

chmod 0644 "$methods_inst/components/example-app/forbid.sh"
assert_exit 1 run_install --profile fresh
assert_eq "[dotsteward] ERROR: component example-app hook forbid: not an executable file: $methods_inst/components/example-app/forbid.sh" "$DS_STDERR"
chmod 0755 "$methods_inst/components/example-app/forbid.sh"

# --generation: the generation's manifest carries absolute script paths.
generation=$DS_TEST_ROOT/generation
mkdir -p "$generation/home-path/share/dotsteward"
jq --arg root "$methods_inst" --arg fw "$methods_fw" '
  .hooks |= map_values(map(.script |= (sub("^<instance>"; $root) | sub("^<dotsteward>"; $fw))))
  | .components = [.components[] | select(.name == "example-app")]' \
  "$methods_manifest" >"$generation/home-path/share/dotsteward/manifest.json"
rm -f "$order"
assert_exit 0 run_install --profile fresh --generation "$generation"
assert_eq "app system
app post early
app post main
app forbid" "$(<"$order")"
