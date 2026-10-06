# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # Nix expressions and jq filters in single quotes
# The shell component seed (5.6): valid, sufficient for the component (the
# fixture lock is the minimal instance lock merged with the seed fragment
# and builds the component), and in line with the locked nixpkgs.
# shellcheck source=tests/nix/components/shell/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/shell/helpers.sh"

seed=$DS_REPO_ROOT/modules/components/shell/seed.json
[[ -f $seed ]] || ds_fail "missing $seed"

json_check "$(<"$seed")" '{schema_version, component, flake_inputs}' \
  '{"component":"shell","flake_inputs":{},"schema_version":1}'
json_check "$(<"$seed")" '.versions_lock | keys' '["nix_packages"]'
json_check "$(<"$seed")" '.versions_lock.nix_packages | keys' '["starship","zsh"]'

# The seed validates against schema/seed.schema.json.
python=$(nix_lib_jsonschema_python)
"$python" - "$DS_REPO_ROOT/schema/seed.schema.json" "$seed" <<'PY' || ds_fail "seed.json does not validate"
import json, sys
import jsonschema
schema = json.load(open(sys.argv[1], encoding="utf-8"))
jsonschema.Draft202012Validator(schema).validate(json.load(open(sys.argv[2], encoding="utf-8")))
PY

# The fixture lock is the minimal lock deep-merged with the seed fragment.
merged=$(jq -S -s '.[0] * .[1].versions_lock' \
  "$DS_REPO_ROOT/tests/fixtures/instances/minimal/versions.lock.json" "$seed")
assert_eq "$merged" "$(jq -S . "$shell_fixture/versions.lock.json")" "fixture lock = minimal lock + seed"

# Seed values agree with what the component resolves on the locked nixpkgs.
assert_eq "$(jq -cS '[.versions_lock.nix_packages.starship.resolved, .versions_lock.nix_packages.zsh.resolved]' "$seed")" \
  "$(shell_eval "$shell_fixture" '[ i.lib.pinnedVersions.starship i.lib.pinnedVersions.zsh ]' | jq -cS .)" \
  "seed resolved versions"
json_check "$(<"$seed")" '.versions_lock.nix_packages.starship | [.expected == .resolved, .official_tag == "v" + .expected, .expected]' \
  '[true,true,"1.26.0"]'
json_check "$(<"$seed")" '.versions_lock.nix_packages.zsh.expected' '"locked nixpkgs package"'
