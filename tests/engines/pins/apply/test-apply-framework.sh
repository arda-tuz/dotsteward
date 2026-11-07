# shellcheck shell=bash
# The framework row: a minor or a patch moves, with bootstrap.sh and the launcher
# refreshed from the template of the new release; a major is a review item; a
# commit pin moves to the tag; a failure leaves the old release in place.
# shellcheck source=tests/engines/pins/apply/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/apply/helpers.sh"

apply_world
framework() {
  row framework framework "$1" "$2" review '{"tag":"'"$2"'","upstream":"github:example/dotsteward"}'
}

# A major: the item names it, nothing moves.
before=$(tree_state)
rows "$(framework v1.2.0 v2.0.0)"
assert_exit 3 apply --latest "$rows"
assert_eq "framework-major framework" "$(item_codes)"
assert_eq "$before" "$(tree_state)"

# A minor moves.
rows "$(framework v1.2.0 v1.3.0)"
assert_exit 0 apply --latest "$rows" --json
assert_eq true "$(jq -c .framework_moved <<<"$DS_STDOUT")"
assert_contains "$(<"$inst/flake.nix")" '"github:example/dotsteward/v1.3.0"'
assert_eq '"v1.3.0"' "$(json_get "$inst/flake.lock" .nodes.dotsteward.original.ref)"
assert_eq "bootstrap of 1.3.0" "$(<"$inst/bootstrap.sh")"
assert_eq "launcher of 1.3.0" "$(<"$inst/.dotsteward/cli.sh")"
assert_eq "755 755" "$(stat -c %a "$inst/bootstrap.sh" "$inst/.dotsteward/cli.sh" | tr '\n' ' ' | sed 's/ $//')"
assert_contains "$(<"$FAKE_NIX_STATE/calls")" "dotstewardMirrors"
assert_exit 0 pins check

# A template that lacks a file: the old release stays, the other rows go on.
git -C "$inst" add -A
git -C "$inst" commit -q -m "framework 1.3.0"
_apply_framework v1.3.1 1.3.1
rm -f -- "$FAKE_NIX_STATE/framework/v1.3.1/template/bootstrap.sh"
digest=$(printf '%064d' 7)
before=$(sha256sum "$inst/flake.nix" "$inst/flake.lock" "$inst/.dotsteward/cli.sh")
rows \
  "$(framework v1.3.0 v1.3.1)" \
  "$(row agent_tools.example-release github-release 4.0.0 4.1.0 update '{"tag":"v4.1.0","size":1,"sha256":"'"$digest"'","url":"https://downloads.example.invalid/example-release/v4.1.0/example-release-linux-x64.tar.gz"}')"
assert_exit 1 apply --latest "$rows"
assert_contains "$DS_STDERR" "template"
assert_eq "$before" "$(sha256sum "$inst/flake.nix" "$inst/flake.lock" "$inst/.dotsteward/cli.sh")"
assert_eq '"4.1.0"' "$(json_get "$versions" '.agent_tools["example-release"].minimum_version')"

# A commit pin: the version comes from the source of the pinned commit, the
# reference becomes the tag.
rev=$(printf 'd%.0s' {1..40})
sed -i "s|github:example/dotsteward/v1.3.0|github:example/dotsteward/$rev|" "$inst/flake.nix"
json_edit "$inst/flake.lock" '
original = data["nodes"]["dotsteward"]["original"]
del original["ref"]
original["rev"] = "'"$rev"'"
'
_apply_framework "$rev" 1.3.0
_apply_framework v1.4.0 1.4.0
_apply_framework v2.1.0 2.1.0
git -C "$inst" add -A
git -C "$inst" commit -q -m "framework on a commit"
rows "$(row framework framework "${rev:0:12}" v2.1.0 review '{"tag":"v2.1.0","rev":"'"$rev"'","contains":false}')"
before=$(tree_state)
assert_exit 3 apply --latest "$rows"
assert_eq "framework-major framework" "$(item_codes)"
assert_eq "$before" "$(tree_state)"
rows "$(row framework framework "${rev:0:12}" v1.4.0 review '{"tag":"v1.4.0","rev":"'"$rev"'","contains":false}')"
assert_exit 0 apply --latest "$rows"
assert_contains "$(<"$inst/flake.nix")" '"github:example/dotsteward/v1.4.0"'
assert_eq "launcher of 1.4.0" "$(<"$inst/.dotsteward/cli.sh")"
