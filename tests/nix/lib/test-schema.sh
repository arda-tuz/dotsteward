# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# schema/workstation.schema.json: a valid JSON Schema (draft 2020-12) in the
# keyword subset that lib/config.nix interprets, closed everywhere except
# component options, and in agreement with an independent validator
# (python jsonschema) on every fixture.
# shellcheck source=tests/nix/lib/helpers.sh
source "$DS_REPO_ROOT/tests/nix/lib/helpers.sh"

schema=$DS_REPO_ROOT/schema/workstation.schema.json
[[ -f $schema ]] || ds_fail "missing $schema"
jq -e . "$schema" >/dev/null || ds_fail "schema is not valid JSON"
assert_eq '"https://json-schema.org/draft/2020-12/schema"' "$(jq -c '."$schema"' "$schema")" "schema dialect"

# Schema nodes: the root and every subschema reachable through the
# supported applicator keywords.
# shellcheck disable=SC2016 # jq program, not shell
nodes='def nodes: ., ((.properties // {} | .[]), (."$defs" // {} | .[]), (.items // empty),
  (.additionalProperties | objects), (.propertyNames // empty) | nodes);'

# Only the interpreted keyword subset appears.
# shellcheck disable=SC2016 # JSON Schema keyword names, not expansions
supported='["$schema","$id","$defs","$ref","$comment","title","description","default","type","enum","const","pattern","minLength","minimum","maximum","items","minItems","uniqueItems","properties","required","additionalProperties","propertyNames"]'
unsupported=$(jq -c --argjson ok "$supported" "$nodes"' [nodes | keys[]] | unique - $ok' "$schema")
assert_eq '[]' "$unsupported" "keywords outside the supported subset"

# Every object schema states additionalProperties, and only component
# options are open.
open=$(jq -c "$nodes"' [nodes | select(.type? == "object" and (has("additionalProperties") | not))] | length' "$schema")
assert_eq 0 "$open" "object schemas without additionalProperties"
open_true=$(jq -c "$nodes"' [nodes | select(.additionalProperties? == true) | .description]' "$schema")
assert_eq 1 "$(jq length <<<"$open_true")" "exactly one open table (component options): $open_true"
assert_eq '{"type":"object","additionalProperties":true}' \
  "$(jq -c '."$defs".component.properties.options | {type, additionalProperties}' "$schema")" "component options are open"

# Nix interprets the same file.
assert_nix_eq "$(jq -c . "$schema")" 'dsLib.config.schema' "exported schema equals the file"

# The independent validator: every valid fixture passes, invalid fixtures
# fail exactly when their "# jsonschema:" line says so (semantic rules such
# as profile references are beyond JSON Schema).
python=$(nix_lib_jsonschema_python)
results=$("$python" - "$schema" "$nix_lib_fixtures" <<'PY'
import json, pathlib, sys, tomllib
from jsonschema import Draft202012Validator
schema = json.loads(pathlib.Path(sys.argv[1]).read_text())
Draft202012Validator.check_schema(schema)
validator = Draft202012Validator(schema)
root = pathlib.Path(sys.argv[2])
for path in sorted(root.glob("*/*.toml")):
    data = tomllib.loads(path.read_text())
    status = "valid" if validator.is_valid(data) else "invalid"
    print(f"{path.parent.name}/{path.name} {status}")
PY
)
count=0
while read -r name status; do
  count=$((count + 1))
  case $name in
    valid/*) expected=valid ;;
    invalid/*) expected=$(sed -n 's/^# jsonschema: //p' "$nix_lib_fixtures/$name") ;;
    *) ds_fail "unexpected fixture $name" ;;
  esac
  assert_eq "$expected" "$status" "python jsonschema on $name"
done <<<"$results"
((count >= 18)) || ds_fail "too few fixtures checked: $count"
