# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# schema/context.schema.json: a valid JSON Schema (draft 2020-12) that requires
# every field of the context document, closes every object (a new field is a
# schema change), and rejects documents that break it. The outputs of the rich
# and the minimal instance are validated in test-context.sh and test-sources.sh.
# shellcheck source=tests/cli/context/helpers.sh
source "$DS_REPO_ROOT/tests/cli/context/helpers.sh"

schema=$DS_REPO_ROOT/schema/context.schema.json
[[ -f $schema ]] || ds_fail "missing $schema"
jq -e . "$schema" >/dev/null || ds_fail "schema is not valid JSON"
assert_eq '"https://json-schema.org/draft/2020-12/schema"' "$(jq -c '."$schema"' "$schema")" "schema dialect"
assert_eq '"https://github.com/arda-tuz/dotsteward/schema/context.schema.json"' "$(jq -c '."$id"' "$schema")"

# Every field of the context document is required.
required() {
  jq -c "$1.required | sort" "$schema"
}
assert_eq '["commit","components","framework","gate","identity","instance","overlays","platform","profiles","protected","schema_version","settings","skills","state"]' "$(required '')"
assert_eq '["branch","checkout","name","path","remote","upstream_contribute"]' "$(required .properties.instance)"
assert_eq '["check_home","check_username","runtime_home","runtime_matches_check","runtime_user"]' "$(required .properties.identity)"
assert_eq '["candidate","log","memo","root","validation"]' "$(required .properties.state)"
assert_eq '["bootstrap","check","current","default","modes","names"]' "$(required .properties.profiles)"
assert_eq '["cache_url","min_free_gib","nix_cores","nix_max_jobs","step_keys"]' "$(required .properties.gate)"
assert_eq '["conventional_types","settings_subject","update_subject","upgrade_subject"]' "$(required .properties.commit)"
assert_eq '["dotsteward-contribute","dotsteward-maintain","dotsteward-update"]' "$(required .properties.overlays)"
assert_eq '["commands","enable","method","name","profiles","settings_targets","source"]' "$(required .properties.components.items)"
assert_eq '["buffer_dir","entry_ids","published_ref","target_names"]' "$(required .properties.settings)"
assert_eq '["hm_root","instance_skill_names"]' "$(required .properties.skills)"
assert_eq '["narHash","rev","track","upstream","version"]' "$(required .properties.framework)"
assert_eq '["fast_path","name","system"]' "$(required .properties.platform)"

# Every object schema is closed (maps such as profiles.modes close through
# their value schema).
nodes='def nodes: .. | objects | select(has("type") or has("properties"));'
open=$(jq -c "$nodes"' [nodes | select(.type? == "object" and (has("additionalProperties") | not))] | length' "$schema")
assert_eq 0 "$open" "object schemas without additionalProperties"

# The step keys and the conventional types are fixed lists (one source for
# the gate regex and the skills).
assert_eq '["preflight","static","pins","flake-check","cli-probes"]' "$(jq -c '.properties.gate.properties.step_keys.const' "$schema")"
assert_eq '["feat","fix","perf","refactor","docs","chore","test","build","ci","style","revert"]' \
  "$(jq -c '.properties.commit.properties.conventional_types.const' "$schema")"

# Broken documents are rejected.
export DOTSTEWARD_PLATFORM=linux
inst=$DS_TEST_ROOT/instances/workstation
make_rich_instance "$inst"
doc=$(context_json "$inst")
rejects() {
  jq "$1" <<<"$doc" >"$DS_TEST_ROOT/broken.json"
  if (validate_schema "$DS_TEST_ROOT/broken.json") 2>/dev/null; then
    ds_fail "the schema accepts a document with $1"
  fi
}
jq . <<<"$doc" >"$DS_TEST_ROOT/valid.json"
validate_schema "$DS_TEST_ROOT/valid.json"
rejects '.extra = 1'
rejects '.schema_version = 2'
rejects 'del(.identity.runtime_matches_check)'
rejects '.identity.runtime_matches_check = "yes"'
rejects '.components[0].values = {}'
rejects '.settings.values = ["x"]'
rejects '.overlays["other-skill"] = null'
rejects '.profiles.modes.workstation = "other"'
rejects '.instance.upstream_contribute = "other"'
rejects '.framework.version = "v1"'
rejects '.platform.system = "x86_64-windows"'
