# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Helpers for the pins apply tests (tests/engines/pins/apply). Not a test file.
#
# apply_world builds an offline world for `dotsteward pins apply`:
#   - the green synthetic instance of the pins check tests at $inst, with one
#     more pin of each class the writer knows and a latest declaration for
#     each, committed;
#   - bare git remotes under $github behind url.insteadOf, holding the tags and
#     the upstream skill the rows name;
#   - the fake nix, npm and sampletool of fake-tools first on PATH;
#   - the state root at $state.
#
#   apply ARG...             `dotsteward --instance $inst pins apply ARG...`
#   internal ARG...          the internal command line of the primitives
#   row ID KIND CUR NEW STATUS [DETAILS]   one report row as JSON
#   rows ROW...              writes a pins latest report to $rows
#   fake_hash TEXT           the SRI hash the fake nix answers for TEXT
#   tree_state               a digest of every file of $inst except .git
#   item_codes               "code id" lines of review.json
#   last_report JQ           jq over the newest report of pins-apply

# shellcheck source=tests/engines/pins/check/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/check/helpers.sh"
# shellcheck source=tests/lib/bare-remote.sh
source "$DS_REPO_ROOT/tests/lib/bare-remote.sh"

github=$DS_TEST_ROOT/github
sources=$DS_TEST_ROOT/sources
state=$DS_TEST_ROOT/state
rows=$DS_TEST_ROOT/latest.json
manifest=$inst/.dotsteward/manifest.x86_64-linux.json
export FAKE_NIX_STATE=$DS_TEST_ROOT/fake-nix
export DOTSTEWARD_STATE_ROOT=$state

apply() {
  "$DS_REPO_ROOT/cli/dotsteward" --instance "$inst" pins apply "$@"
}

internal() {
  PYTHONPATH=$DS_REPO_ROOT/cli/python PYTHONDONTWRITEBYTECODE=1 python3 -s -P -m dotsteward_cli.internal "$@"
}

row() {
  jq -cn --arg id "$1" --arg kind "$2" --arg current "$3" --arg latest "$4" --arg status "$5" \
    --argjson details "${6:-"{}"}" \
    '{id: $id, kind: $kind, current: $current, latest: $latest, status: $status, source: "synthetic", details: $details}'
}

rows() {
  jq -s '{schema_version: "1.0", researched_at: "2026-11-07T00:00:00Z", items: .}' <<<"$*" >"$rows"
}

fake_hash() {
  python3 -c 'import base64, hashlib, sys; print("sha256-" + base64.b64encode(hashlib.sha256(sys.argv[1].encode()).digest()).decode())' "$1"
}

tree_state() {
  (cd "$inst" && find . -path ./.git -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum)
}

item_codes() {
  jq -r '.items[] | "\(.code) \(.id)"' "$state/review.json"
}

last_report() {
  local newest
  newest=$(jq -r --slurp 'max_by(.sequence) | .run' "$state"/runs/pins-apply/*.json)
  jq -c "$1" "$state/runs/pins-apply/$newest.json"
}

_apply_remote() {
  local name=$1 dir
  shift
  dir=$sources/$name
  mkdir -p "$(dirname "$dir")"
  ds_git_repo "$dir"
  local tag
  for tag in "$@"; do
    ds_git_commit "$dir" VERSION "$tag" "chore: $tag"
    git -C "$dir" tag -a "$tag" -m "release $tag"
  done
  _apply_publish "$name"
}

_apply_publish() {
  local bare=$github/$1
  rm -rf -- "$bare"
  mkdir -p "$(dirname "$bare")"
  ds_bare_remote "$bare" "$sources/$1"
}

# The upstream of example-vendored at the revision the lock pins, then a second
# commit that changes it.
_apply_skill_upstream() {
  local dir=$sources/example/skills
  mkdir -p "$dir/skills"
  git -C "$dir" init -q -b main
  cp -R "$inst/agent/skills/example-vendored" "$dir/skills/example-vendored"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "feat: the example skill"
  skill_old=$(git -C "$dir" rev-parse HEAD)
  printf '# Notes\n\nA second version with a new file.\n' >"$dir/skills/example-vendored/references/notes.md"
  printf 'new\n' >"$dir/skills/example-vendored/references/added.md"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "feat: a second version"
  skill_new=$(git -C "$dir" rev-parse HEAD)
  _apply_publish example/skills
}

_apply_framework() {
  local source=$FAKE_NIX_STATE/framework/$1
  mkdir -p "$source/template/.dotsteward"
  printf '%s\n' "$2" >"$source/VERSION"
  printf 'bootstrap of %s\n' "$2" >"$source/template/bootstrap.sh"
  printf 'launcher of %s\n' "$2" >"$source/template/.dotsteward/cli.sh"
  chmod 0444 "$source/template/bootstrap.sh" "$source/template/.dotsteward/cli.sh"
}

apply_world() {
  mkdir -p "$github" "$sources" "$state" "$FAKE_NIX_STATE"
  git config --global url."$github/".insteadOf https://github.com/
  export PATH=$DS_REPO_ROOT/tests/engines/pins/apply/fake-tools:$PATH

  pins_instance

  # The framework input on a release tag; the sources of newer releases.
  sed -i 's|github:example/dotsteward/v0.1.0|github:example/dotsteward/v1.2.0|' "$inst/flake.nix"
  json_edit "$inst/flake.lock" 'data["nodes"]["dotsteward"]["original"]["ref"] = "v1.2.0"'
  printf 'bootstrap of 1.2.0\n' >"$inst/bootstrap.sh"
  mkdir -p "$inst/.dotsteward"
  printf 'launcher of 1.2.0\n' >"$inst/.dotsteward/cli.sh"
  chmod 0755 "$inst/bootstrap.sh" "$inst/.dotsteward/cli.sh"
  _apply_framework v1.2.1 1.2.1
  _apply_framework v1.3.0 1.3.0
  _apply_framework v2.0.0 2.0.0

  _apply_remote example/example-term v1.2.0 v1.3.0 v2.0.0
  _apply_remote example/example-release v4.0.0 v4.1.0 v5.0.0
  _apply_remote example/example-app v3.1.0 v3.2.0
  _apply_remote example/example-cli v2.0.0 v2.1.0
  _apply_remote example/nixpkgs
  _apply_skill_upstream

  json_edit "$versions" '
inputs = data["flake_inputs"]
inputs["nixpkgs"]["channel"] = "example-26.05"
tools = data["agent_tools"]
tools["example-release"]["source"] = "https://github.com/example/example-release"
tools["example-app"]["source"] = "https://github.com/example/example-app"
tools["example-app"]["tag_revision"] = "0" * 40
tools["example-cli"]["source"] = "https://github.com/example/example-cli"
tools["example-cli"]["source_revision"] = "0" * 40
tools["example-market"] = {"source": "https://github.com/example/market", "observed_marketplace_revision": "1" * 40}
tools["example-compat"] = {"version": "1.0.0", "compatibility_reason": "another tool needs exactly this version"}
tools["example-plain"] = {"version": "1.0.0"}
data["example_watch"] = {"source": "https://github.com/example/watched", "inspected_revision": "2" * 40}
data["pypi"] = {"example-tool": {"version": "1.0.0"}}
'
  json_edit "$skills" '
data["skills"][1]["revision"] = "'"$skill_old"'"
data["skills"][1]["source_path"] = "skills/example-vendored"
'
  mkdir -p "$inst/components/example-tool"
  printf 'example-tool==1.0.0 \\\n    --hash=sha256:%064d\n' 0 >"$inst/components/example-tool/requirements.txt"
  json_edit "$manifest" '
data["components"] = [{"name": "example-tool", "install": {"pin": "pypi.example-tool", "python": "/usr/bin/python3"}}]
data["pins"]["rules"].append({"component": "example-tool", "kind": "text-guard", "file": "components/example-tool/requirements.txt", "template": "example-tool=={pypi.example-tool.version}"})
release = {"component": "example-release", "id": "agent_tools.example-release", "adapter": "github-release", "at": "agent_tools.example-release", "repo": "example/example-release", "tag_prefix": "v"}
data["pins"]["latest"] = [
    release,
    {"component": "example-desktop", "id": "desktop_packages.example-desktop", "adapter": "official-manifest", "at": "desktop_packages.example-desktop", "current_field": "minimum_version", "manifest_url": "https://downloads.example.invalid/manifest.json", "version_field": "version", "sha256_field": "sha256", "size_url_field": "url", "url_template": "https://downloads.example.invalid/example-desktop_{version}_amd64.deb"},
    {"component": "example-bundle", "id": "npm.{key}", "adapter": "npm", "for_each": "skills:npm_tools", "package": "{key}", "current": "{value}"},
    {"component": "example-bundle", "id": "npm_security_overrides.{key}", "adapter": "npm", "for_each": "agent_tools.npm_security_overrides", "package": "{key}", "current_field": "version"},
    {"component": "example-app", "id": "agent_tools.example-app", "adapter": "npm", "at": "agent_tools.example-app", "package": "example-app"},
    {"component": "example-market", "id": "agent_tools.example-market", "adapter": "git-compare", "at": "agent_tools.example-market", "repo_at": ".source", "revision_at": ".observed_marketplace_revision", "watched": [".*"]},
    {"component": "example-watch", "id": "example_watch", "adapter": "git-compare", "repo_at": "example_watch.source", "revision_at": "example_watch.inspected_revision", "watched": [".*"]},
    {"component": "example-compat", "id": "agent_tools.example-compat", "adapter": "npm", "at": "agent_tools.example-compat", "package": "example-compat"},
    {"component": "example-plain", "id": "agent_tools.example-plain", "adapter": "npm", "at": "agent_tools.example-plain", "package": "example-plain"},
    {"component": "example-tool", "id": "pypi.example-tool", "adapter": "pypi", "package": "example-tool"},
]
'
  cat >"$FAKE_NIX_STATE/packages.json" <<'JSON'
{
  "example-term": {"src": {"hash": "nix_packages.example-term.source_nix_sha256", "version": "nix_packages.example-term.expected"}},
  "example-app": {"src": {"hash": "agent_tools.example-app.source_nix_sha256", "version": "agent_tools.example-app.version"}},
  "example-bundle": {"npmDeps": {"hash": "agent_tools.npm_bundle_nix_sha256", "file": "packages/example-bundle/package-lock.json"}}
}
JSON
  cat >"$FAKE_NIX_STATE/pinned.json" <<'JSON'
{"example-lint": "nix_packages.example-lint.expected", "example-term": "nix_packages.example-term.expected"}
JSON
  # What the instance builds today is in the store: Nix would answer a stale
  # hash without a mismatch.
  jq -r '.nix_packages["example-term"].source_nix_sha256, .agent_tools["example-app"].source_nix_sha256, .agent_tools.npm_bundle_nix_sha256' \
    "$versions" >"$FAKE_NIX_STATE/store"

  git -C "$inst" add -A
  git -C "$inst" commit -q -m "synthetic instance with every class of pin"
  : >"$FAKE_NIX_STATE/calls"
}
