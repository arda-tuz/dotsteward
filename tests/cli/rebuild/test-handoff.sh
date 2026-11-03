# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# The gate-to-rebuild hand-off: `dotsteward gate` records the generation it
# built in <state>/update/generation.json (tree_oid, profile, system,
# username, home, generation, framework_override, root). rebuild reuses
# that generation, without evaluating or building and without touching the
# host overrides, only when every field matches this rebuild: the tree of
# HEAD, --profile, the primary system, $USER, $HOME, the framework
# override and the checkout, and the generation is a valid store path
# (`nix path-info`) with an activate script. Any difference, and a stale,
# corrupt or loosely protected record, builds exactly as without one. The
# activation record then names the reused generation like a built one.
# shellcheck source=tests/cli/rebuild/helpers.sh
source "$DS_REPO_ROOT/tests/cli/rebuild/helpers.sh"

record=$rb_state/update/generation.json
gate_generation=$(make_generation gate-generation)
ref='git+file:///srv/dotsteward?rev=0123456789abcdef0123456789abcdef01234567'

# handoff [JQ_FILTER]: writes the record the gate writes for HEAD and the
# workstation profile, changed by JQ_FILTER.
handoff() {
  mkdir -p "$rb_state/update"
  chmod 0700 "$rb_state" "$rb_state/update"
  rm -f -- "$record"
  jq -n --arg tree "$(git -C "$rb_inst" rev-parse 'HEAD^{tree}')" --arg user "$USER" --arg home "$HOME" \
    --arg generation "$gate_generation" --arg root "$rb_inst" '{
      schema_version: "1.0", tree_oid: $tree, profile: "workstation", system: "x86_64-linux",
      username: $user, home: $home, generation: $generation, framework_override: null,
      root: $root, recorded_at: "2026-01-01T00:00:00Z"}' | jq "${1:-.}" >"$record"
  chmod 0600 "$record"
}

# reused ARG...: rebuild ARG... activates or records the gate's generation
# without a Nix evaluation and leaves the host overrides alone.
reused() {
  local hosts
  hosts=$(tree_state "$rb_hosts")
  : >"$DS_CALL_LOG"
  assert_exit 0 run_rebuild "$@"
  assert_contains "$DS_STDOUT" "[dotsteward] reusing the generation the gate built for this tree: $gate_generation"
  assert_not_contains "$DS_STDOUT" "building the Home Manager activation package"
  assert_eq 0 "$(ds_call_count nix '* build *')" "a reused generation was built"
  assert_eq 0 "$(ds_call_count nix '* flake *')" "a reused generation touched the host lock"
  assert_eq "$hosts" "$(tree_state "$rb_hosts")" "a reused generation changed the host overrides"
  assert_eq "$gate_generation" "$(<"$rb_current/last-built-activation")"
}

# built ARG...: rebuild ARG... evaluates and builds as without a record.
built() {
  : >"$DS_CALL_LOG"
  assert_exit 0 run_rebuild "$@"
  assert_not_contains "$DS_STDOUT" "reusing the generation"
  assert_contains "$DS_STDOUT" "[dotsteward] building the Home Manager activation package"
  assert_eq 1 "$(ds_call_count nix '* build *')"
  [[ $(<"$rb_current/last-built-activation") != "$gate_generation" ]] || ds_fail "the gate's generation was used"
}

# Without a record: the build as always (and the host lock is created).
built --profile workstation --build-only

# --- reuse -----------------------------------------------------------------------

handoff
reused --profile workstation --build-only
assert_eq "workstation" "$(<"$rb_current/profile")"
assert_eq 0 "$(ds_call_count activate)"

handoff
reused --profile workstation --switch
assert_eq 1 "$(ds_call_count activate)"
jq -e --arg generation "$gate_generation" --arg revision "$(git -C "$rb_inst" rev-parse HEAD)" \
  --arg tree "$(git -C "$rb_inst" rev-parse 'HEAD^{tree}')" --arg root "$rb_inst" '
  .generation == $generation and .profile == "workstation" and .revision == $revision
  and .tree_oid == $tree and .root == $root and .framework_override == null' \
  "$rb_current/activation.json" >/dev/null || ds_fail "unexpected activation record: $(<"$rb_current/activation.json")"
assert_eq 1 "$(ds_call_count local-maintained-files)"

# The same override as the record.
handoff ".framework_override = \"$ref\""
reused --profile workstation --build-only --framework-override "$ref"

# --- any difference builds ----------------------------------------------------------

handoff
built --profile fresh --build-only
handoff
built --profile workstation --build-only --framework-override "$ref"
handoff ".framework_override = \"$ref\""
built --profile workstation --build-only
handoff ".framework_override = \"path:/srv/other\""
built --profile workstation --build-only --framework-override "$ref"
handoff '.tree_oid = "0000000000000000000000000000000000000000"'
built --profile workstation --build-only
handoff '.username = "other"'
built --profile workstation --build-only
handoff '.home = "/home/other"'
built --profile workstation --build-only
handoff '.system = "aarch64-darwin"'
built --profile workstation --build-only
handoff ".root = \"$DS_TEST_ROOT/another-checkout\""
built --profile workstation --build-only

# A new commit: the record is stale.
handoff
printf '# changed\n' >>"$rb_inst/flake.nix"
instance_commit "a new revision"
built --profile workstation --build-only
assert_contains "$DS_STDOUT" "[dotsteward] instance source changed; refreshing the host input lock"

# --- stale, corrupt or tampered records build --------------------------------------

handoff
reused --profile workstation --build-only

handoff '.schema_version = "9.9"'
built --profile workstation --build-only
handoff 'del(.generation)'
built --profile workstation --build-only
handoff '.generation = "/tmp/elsewhere-home-manager-generation"'
built --profile workstation --build-only
handoff ".generation = \"$gate_generation/home-path\""
built --profile workstation --build-only
handoff ".generation = \"$rb_store/../store/$(basename "$gate_generation")\""
built --profile workstation --build-only
handoff ".generation = \"$rb_store/00000000000000000000000000000000-missing\""
built --profile workstation --build-only

# A store path Nix does not know (collected, or never valid).
handoff
printf '%s\n' "$gate_generation" >"$DS_TEST_ROOT/invalid-paths"
built --profile workstation --build-only
rm -f -- "$DS_TEST_ROOT/invalid-paths"

# A generation without an activate script.
broken=$(make_generation broken-generation)
chmod -x "$broken/activate"
handoff ".generation = \"$broken\""
built --profile workstation --build-only

printf 'not json\n' >"$record"
built --profile workstation --build-only

handoff
chmod 0666 "$record"
built --profile workstation --build-only

handoff
mv "$record" "$DS_TEST_ROOT/record-elsewhere.json"
ln -s "$DS_TEST_ROOT/record-elsewhere.json" "$record"
built --profile workstation --build-only

# The record is read, never written, by rebuild.
handoff
before=$(sha256sum <"$record")
reused --profile workstation --switch
assert_eq "$before" "$(sha256sum <"$record")"
