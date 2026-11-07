# shellcheck shell=bash
# A pypi pin and its hash-pinned requirements move together (T17-a): the file
# the text-guard rule names is regenerated with the command the rule declares
# (the framework names no compiler); a failure restores both.
# shellcheck source=tests/engines/pins/apply/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/apply/helpers.sh"

apply_world
requirements=$inst/components/example-tool/requirements.txt

rows "$(row pypi.example-tool pypi 1.0.0 1.1.0 update '{"requires_python":">=3.11"}')"
: >"$FAKE_NIX_STATE/fail-compiler"
before=$(tree_state)
assert_exit 1 apply --latest "$rows"
assert_contains "$DS_STDERR" "no solution found"
assert_eq "$before" "$(tree_state)"
rm -f -- "$FAKE_NIX_STATE/fail-compiler"

assert_exit 0 apply --latest "$rows"
assert_contains "$(<"$requirements")" "example-tool==1.1.0 \\"
assert_contains "$(<"$requirements")" "example-transitive==1.0.0"
assert_contains "$(<"$requirements")" "--hash=sha256:"
assert_eq '"1.1.0"' "$(json_get "$versions" '.pypi["example-tool"].version')"
assert_contains "$(<"$FAKE_NIX_STATE/calls")" "nixpkgs#example-compiler"
assert_contains "$(<"$FAKE_NIX_STATE/calls")" "--python /usr/bin/python3"
assert_exit 0 pins check

# A guarded requirements file without a declared command has no writer.
json_edit "$manifest" '
for rule in data["pins"]["rules"]:
    rule.pop("regenerate", None)
'
git -C "$inst" add -A
git -C "$inst" commit -q -m "no command to regenerate"
before=$(tree_state)
rows "$(row pypi.example-tool pypi 1.1.0 1.2.0 update)"
assert_exit 3 apply --latest "$rows"
assert_eq "pins-no-writer pypi.example-tool" "$(item_codes)"
assert_eq "$before" "$(tree_state)"

# A pypi pin without a guarded requirements file has no writer.
json_edit "$manifest" 'data["pins"]["rules"] = [rule for rule in data["pins"]["rules"] if rule["kind"] != "text-guard" or "requirements" not in rule["file"]]'
git -C "$inst" add -A
git -C "$inst" commit -q -m "no requirements rule"
before=$(tree_state)
rows "$(row pypi.example-tool pypi 1.1.0 1.2.0 update)"
assert_exit 3 apply --latest "$rows"
assert_eq "pins-no-writer pypi.example-tool" "$(item_codes)"
assert_eq "$before" "$(tree_state)"
