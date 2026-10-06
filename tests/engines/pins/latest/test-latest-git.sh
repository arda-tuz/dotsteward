# shellcheck shell=bash
# Git based rows: channel-head (update when the channel moved, error when
# the channel is gone, declared rows replacing the built-in one), compares
# (no compare call when nothing moved, a truncated file list is a review,
# release-bound skills without a GitHub release and with a moved tag), the
# skills lock without vendored files, and nix-release when nothing is newer.
# shellcheck source=tests/engines/pins/latest/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/latest/helpers.sh"

latest_world

# --- channel-head --------------------------------------------------------------

ds_git_commit "$sources/example-org/home-manager" release.txt moved "chore: move the channel"
git -C "$sources/example-org/home-manager" branch -f release-25.11 main
publish example-org/home-manager
pinned=$(jq -r '.flake_inputs."home-manager".revision' "$versions")
head=$(rev example-org/home-manager release-25.11)
[[ $pinned != "$head" ]] || ds_fail "the channel did not move"
assert_exit 0 latest --out "$report"
assert_eq "[\"${pinned:0:12}\",\"${head:0:12}\",\"update\",{\"channel\":\"release-25.11\",\"head\":\"$head\",\"newest_series\":\"release-25.11\"}]" \
  "$(row flake_inputs.home-manager '[.current, .latest, .status, .details]')"

# A newer release series makes it a review.
git -C "$sources/example-org/home-manager" branch release-26.05 main
publish example-org/home-manager
assert_exit 0 latest --out "$report"
assert_eq '["review","release-26.05"]' "$(row flake_inputs.home-manager '[.status, .details.newest_series]')"

# The pinned channel no longer exists: an error row.
json_edit "$versions" 'pin = data["flake_inputs"]["home-manager"]; pin["channel"] = "release-24.05"; pin["reference"] = "github:example-org/home-manager/release-24.05"'
assert_exit 1 latest --out "$report"
assert_eq "[\"channel-head\",\"${pinned:0:12}\",null,\"error\",{\"channel\":\"release-24.05\",\"head\":null,\"newest_series\":\"release-26.05\"}]" \
  "$(row flake_inputs.home-manager '[.kind, .current, .latest, .status, .details]')"

# A declared channel-head row replaces the built-in one: explicit git URL
# and series prefix.
json_edit "$versions" 'pin = data["flake_inputs"]["home-manager"]; pin["channel"] = "release-25.11"'
ln -s home-manager "$github/example-org/home-manager.git"
declare_latest '{"component":"example-hm","id":"flake_inputs.home-manager","adapter":"channel-head","url":"https://github.com/example-org/home-manager.git","prefix":"release-"}'
assert_exit 0 latest --out "$report"
assert_eq 1 "$(jq '[.items[] | select(.id == "flake_inputs.home-manager")] | length' "$report")"
assert_eq '["review","https://github.com/example-org/home-manager.git"]' "$(row flake_inputs.home-manager '[.status, .source]')"

# --- compares --------------------------------------------------------------------

# Nothing moved: no compare call.
tip=$(rev example-org/example-plugins main)
json_edit "$versions" "data['agent_tools']['example-plugin']['observed_revision'] = '$tip'"
declare_latest '{"component":"example-plugin","id":"agent_tools.example-plugin","adapter":"git-compare","at":"agent_tools.example-plugin","repo_at":".source","revision_at":".observed_revision","watched":["plugins/example-web/.+"]}'
: >"$DS_CALL_LOG"
assert_exit 0 latest --out "$report"
assert_eq "[\"current\",\"${tip:0:12}\",\"${tip:0:12}\",0,[]]" \
  "$(row agent_tools.example-plugin '[.status, .current, .latest, .details.ahead_by, .details.changed_paths]')"
assert_call_count 0 gh "api repos/example-org/example-plugins/compare/*"

# A compare that lists 300 files may be truncated: review even without a
# watched path.
python3 - "$DS_TEST_ROOT/compare-300.json" <<'PY'
import json
import sys

files = [{"filename": f"docs/page-{index:03d}.md", "status": "added"} for index in range(300)]
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"ahead_by": 7, "files": files}, handle)
PY
ds_stub_clear_routes gh
ds_stub_route gh "api repos/example-org/example-watch/compare/*" --stdout-file "$DS_TEST_ROOT/compare-300.json"
latest_gh_routes
declare_latest '{"component":"example-watch","id":"example_watch","adapter":"git-compare","at":"example_watch","repo":"example-org/example-watch","revision_at":".inspected_revision","watched":["README\\.md"]}'
assert_exit 0 latest --out "$report"
assert_eq '["review",7,[],true]' "$(row example_watch '[.status, .details.ahead_by, .details.changed_paths, .details.files_truncated]')"

# A release-bound skill: without a GitHub release the newest stable tag
# answers; when the tag moved past the pinned revision, the compare runs
# against the tag's commit (an annotated tag is peeled).
ds_stub_clear_routes gh
ds_stub_route gh "api repos/example-org/example-tool/compare/*" --stdout '{"ahead_by": 2, "files": [{"filename": "skill/SKILL.md"}]}'
ds_stub_route gh "api repos/example/dotsteward/releases/latest" --stdout '{"tag_name": "v0.2.0"}'
ds_stub_route gh "api repos/example-org/example-skills/compare/*" --stdout-file "$latest_fixtures/gh/compare-skills.json"
ds_stub_route gh "api repos/example-org/example-plugins/compare/*" --stdout-file "$latest_fixtures/gh/compare-plugins.json"
ds_stub_route gh "api repos/example-org/example-watch/compare/*" --stdout-file "$latest_fixtures/gh/compare-watch.json"
ds_stub_route gh "api repos/example-org/example-term/releases/latest" --stdout-file "$(ds_fixture common/github/release-latest.json)"
ds_git_commit "$sources/example-org/example-tool" skill/SKILL.md "# moved" "chore: release 1.1.0"
git -C "$sources/example-org/example-tool" tag -a v1.1.0 -m "release 1.1.0"
publish example-org/example-tool
pinned=$(rev example-org/example-tool v1.0.0)
tagged=$(rev example-org/example-tool v1.1.0)
: >"$DS_CALL_LOG"
assert_exit 0 latest --out "$report"
assert_eq "[\"review\",\"${pinned:0:12}\",\"${tagged:0:12}\",\"v1.1.0\",[\"skill/SKILL.md\"]]" \
  "$(row skills.example-bound '[.status, .current, .latest, .details.release, .details.changed_paths]')"
assert_call_count 1 gh "api repos/example-org/example-tool/releases/latest"
assert_call_count 1 gh "api repos/example-org/example-tool/compare/$pinned...$tagged"

# A skill directory that is not vendored: only the skill structure counts.
json_edit "$skills" 'data["skills"][2]["source_path"] = "."'
ds_stub_clear_routes gh
ds_stub_route gh "api repos/example-org/example-skills/compare/*" \
  --stdout '{"ahead_by": 1, "files": [{"filename": "SKILL.md"}, {"filename": "docs/guide.md"}, {"filename": "skills/example-vendored/SKILL.md"}]}'
latest_gh_routes
assert_exit 0 latest --out "$report"
assert_eq '["review",["SKILL.md"]]' "$(row skills.example-second '[.status, .details.changed_paths]')"
assert_eq '["review",["skills/example-vendored/SKILL.md"]]' "$(row skills.example-vendored '[.status, .details.changed_paths]')"

# Without a skills lock there are no skill rows.
rm -f -- "$skills"
clear_latest
assert_exit 0 latest --out "$report"
assert_json "$report" '[.items[] | select(.id | startswith("skills.") or startswith("npm."))] | length == 0'

# --- nix-release ---------------------------------------------------------------

json_edit "$versions" "pin = data['nix']; pin['version'] = '2.31.1'; pin['installer_url'] = '$DS_HTTPFIX_URL/nix/nix-2.31.1/install'"
assert_exit 0 latest --out "$report"
assert_eq '["nix-release","2.31.1","2.31.1","current"]' "$(row nix.installer '[.kind, .current, .latest, .status]')"

# A lock without the installer section has no nix.installer row.
json_edit "$versions" 'del data["nix"]'
assert_exit 0 latest --out "$report"
assert_eq "" "$(row nix.installer)"
