# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and ct_* variables come from the harness and the helpers
# `dotsteward contribute upgrade --tag TAG` on an instance whose dotsteward
# input follows a branch through a git+ URL (`?ref=main`, as an instance of a
# development framework has it). Nix reads a ref without the refs/ prefix as
# refs/heads/<ref>, so the tag must be written as ?ref=refs/tags/TAG: a bare
# ?ref=TAG makes `nix flake update dotsteward` look for a branch named after
# the tag and fail. Found in the first real contribute round (v0.0.1).
# shellcheck source=tests/contribute/remote/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/remote/helpers.sh"

rt_setup owner
cat >"$ct_inst/flake.nix" <<'EOF'
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/774debe7a0d1b496e35677ad955a1011c6ff74f3";
    dotsteward = {
      url = "git+ssh://git@github.com/example-org/dotsteward.git?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = inputs: inputs.dotsteward.lib.mkInstance { inherit inputs; };
}
EOF
instance_commit "chore: follow the framework's main branch"
released_run branch-url
merged=$(field .merged_sha)

assert_exit 0 run_contribute upgrade --tag v0.1.1 --build-only
assert_contains "$(cat "$ct_inst/flake.nix")" \
  'url = "git+ssh://git@github.com/example-org/dotsteward.git?ref=refs/tags/v0.1.1";'
jq -e --arg sha "$merged" '.nodes.dotsteward.locked.rev == $sha and .nodes.dotsteward.original.ref == "refs/tags/v0.1.1"' \
  "$ct_inst/flake.lock" >/dev/null || ds_fail "flake.lock does not lock the tag v0.1.1"
assert_eq report "$(field .step)" "step after the upgrade"
