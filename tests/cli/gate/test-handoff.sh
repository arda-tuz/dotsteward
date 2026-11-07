# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The gate's half of the gate-to-rebuild hand-off: a passing gate records
# the generation its cli-probes step built and probed in
# <state>/update/generation.json (mode 0600, written atomically):
# schema_version "1.0", tree_oid (the candidate tree), profile (the check
# profile), system (the primary system), username and home (the check
# identity, identity.home on Linux), generation (the built store path),
# framework_override (or null), root and recorded_at. `dotsteward rebuild`
# reuses that generation for an identical tree, profile, identity and
# override. A failed gate and a memo answer keep the previous record.
# shellcheck source=tests/cli/gate/helpers.sh
source "$DS_REPO_ROOT/tests/cli/gate/helpers.sh"

ds_use_stubs nix curl
serve_cache

record=$gate_state/generation.json
ref='git+file:///srv/dotsteward?rev=0123456789abcdef0123456789abcdef01234567'

# expect_record OVERRIDE_JSON: the record names the generation the probes got.
expect_record() {
  local generation
  generation=$(fake_calls | sed -n 's/^probes --generation //p' | tail -n 1)
  [[ -n $generation ]] || ds_fail "no probes call"
  assert_file_mode "$record" 600
  assert_json "$record" '(keys_unsorted) == ["schema_version", "tree_oid", "profile", "system", "username", "home",
    "generation", "framework_override", "root", "host", "tags_sha256", "recorded_at"]'
  jq -e --arg tree "$(add_tree_oid)" --arg generation "$generation" --arg root "$gate_inst" \
    --argjson override "$1" '
    .schema_version == "1.0" and .tree_oid == $tree and .profile == "workstation"
    and .system == "x86_64-linux" and .username == "alice" and .home == "/home/alice"
    and .generation == $generation and .framework_override == $override and .root == $root
    and (.recorded_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' "$record" >/dev/null ||
    ds_fail "unexpected hand-off record: $(<"$record")"
  assert_eq "" "$(find "$gate_state" -name '.generation.json.*' -print)" "temporary files left behind"
}

assert_exit 0 run_gate --scope maintain
expect_record null

# A memo answer keeps it.
saved=$(<"$record")
: >"$DS_CALL_LOG"
assert_exit 0 run_gate --scope maintain
assert_contains "$DS_STDOUT" "already passed the gate"
assert_eq "$saved" "$(<"$record")"

# A failing step keeps it.
mkdir -p "$gate_inst/notes"
printf 'a\n' >"$gate_inst/notes/a.txt"
commit_all "docs: add a note"
step_fail probes 1
: >"$DS_CALL_LOG"
assert_exit 1 run_gate --scope maintain
assert_eq "$saved" "$(<"$record")" "a failed gate changed the hand-off record"
step_fail pins 1
step_fail probes 0
: >"$DS_CALL_LOG"
assert_exit 1 run_gate --scope maintain
assert_eq "$saved" "$(<"$record")" "a failed gate changed the hand-off record"
step_fail pins 0

# The new tree passes and is recorded; so is an override.
: >"$DS_CALL_LOG"
assert_exit 0 run_gate --scope maintain
expect_record null
: >"$DS_CALL_LOG"
assert_exit 0 run_gate --scope maintain --framework-override "$ref"
expect_record "\"$ref\""

# The check identity's home: identity.home when set.
set_toml identity home '"/srv/homes/alice"'
commit_all "chore: move the check home"
: >"$DS_CALL_LOG"
assert_exit 0 run_gate --scope maintain
assert_json "$record" '.home == "/srv/homes/alice" and .username == "alice"'
