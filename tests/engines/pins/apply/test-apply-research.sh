# shellcheck shell=bash
# Without --latest the writer researches itself, like `pins latest`, and an error
# row does not stop it. The fake GitHub remotes answer.
# shellcheck source=tests/engines/pins/apply/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/apply/helpers.sh"

apply_world
ds_use_stubs gh
# The release lists hold no release, so the tags of the fake remotes answer.
ds_stub_route gh "api repos/*/releases?per_page=100&page=1" --stdout '[]'
ds_stub_route gh "api repos/*" --exit 1 --stderr "HTTP 404: Not Found"
git -C "$sources/example/nixpkgs" branch example-26.05
ds_git_commit "$sources/example/nixpkgs" channel.txt moved "chore: the channel moves"
git -C "$sources/example/nixpkgs" branch -f example-26.05 main
_apply_publish example/nixpkgs
rm -rf -- "$sources/example/dotsteward"
_apply_remote example/dotsteward v1.2.0 v1.2.1

# Only rows the fake remotes can answer, and one they cannot.
json_edit "$manifest" '
data["pins"]["latest"] = [
    {"component": "example-release", "id": "agent_tools.example-release", "adapter": "github-release", "at": "agent_tools.example-release", "repo": "example/example-release", "tag_prefix": "v"},
    {"component": "example-gone", "id": "agent_tools.example-plain", "adapter": "github-release", "at": "agent_tools.example-plain", "repo": "example/does-not-exist"},
]
'
json_edit "$skills" 'data["skills"][1]["revision"] = "'"$skill_new"'"'
cp -R "$sources/example/skills/skills/example-vendored/." "$inst/agent/skills/example-vendored/"
"$DS_REPO_ROOT/cli/dotsteward" --instance "$inst" pins sync --skill example-vendored >/dev/null
git -C "$inst" add -A
git -C "$inst" commit -q -m "only some rows"

# The research sees v5.0.0 of example-release: an unconstrained major with no
# asset, so the prefetch fills it. example-term has v2.0.0: its major moves too.
assert_exit 6 apply --json
summary=$DS_STDOUT
assert_eq '"5.0.0"' "$(json_get "$versions" '.agent_tools["example-release"].minimum_version')"
assert_eq '"2.0.0"' "$(json_get "$versions" '.flake_inputs["example-term"].version')"
assert_eq "\"$(fake_hash "example-term.src:2.0.0")\"" "$(json_get "$versions" '.nix_packages["example-term"].source_nix_sha256')"
assert_eq "\"$(git -C "$github/example/nixpkgs" rev-parse main)\"" "$(json_get "$versions" '.flake_inputs.nixpkgs.revision')"
assert_contains "$(<"$inst/flake.nix")" '"github:example/dotsteward/v1.2.1"'
assert_eq "launcher of 1.2.1" "$(<"$inst/.dotsteward/cli.sh")"
assert_contains "$(jq -c '[.lines[] | select(.status == "error")]' <<<"$summary")" "does-not-exist"
assert_contains "$(jq -c .researched_at <<<"$summary")" "Z"
assert_exit 0 pins check

# Researched again, what is left is the error.
: >"$FAKE_NIX_STATE/calls"
before=$(tree_state)
assert_exit 6 apply --json
assert_eq '[]' "$(jq -c .moved <<<"$DS_STDOUT")"
assert_eq "$before" "$(tree_state)"
