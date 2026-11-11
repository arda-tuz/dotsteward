# shellcheck shell=bash
# The research inside a version constraint: a pin whose current version is inside the `version`
# of its component and whose newest release is outside it gets the row of the newest stable release
# inside it, with the newest one in details.outside. An adapter that lists versions (pypi here) is
# searched; one that gives a single version (apt-index) keeps its row and says it is unsearchable. A
# pin outside its constraint already, or of a component without one, is researched as always.
# shellcheck source=tests/engines/pins/latest/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/latest/helpers.sh"

latest_world
url=$DS_HTTPFIX_URL

mkdir -p "$www/pypi/example-app"
file='{"filename": "example_app-x-py3-none-any.whl", "yanked": false, "requires_python": ">=3.9"}'
jq -n --argjson file "$file" '{info: {name: "example-app"}, releases: {
  "1.0.0": [$file], "1.4.0": [$file], "1.5.0rc1": [$file], "1.6.0": [], "2.0.0": [$file]}}' \
  >"$www/pypi/example-app/json"
json_edit "$versions" 'data["pypi"] = {"example-app": {"version": "1.0.0"}}'
mkdir -p "$www/apt/dists/stable/main/binary-amd64"
declare_latest \
  "{\"component\":\"example-app\",\"id\":\"pypi.example-app\",\"adapter\":\"pypi\",\"package\":\"example-app\",\"index\":\"$url/pypi\"}"

# No constraint: the newest.
assert_exit 0 latest --out "$report"
assert_eq '["2.0.0","review",null]' "$(row pypi.example-app '[.latest, .status, .details.outside]')"

# Inside 1.*: the newest final release with files inside it, the new series kept beside it.
printf '\n[components.example-app]\nenable = true\nversion = "1.*"\nreason = "the 1.x protocol"\n' >>"$inst/workstation.toml"
assert_exit 0 latest --out "$report"
assert_eq '["1.4.0","update",{"latest":"2.0.0","status":"review"}]' "$(row pypi.example-app '[.latest, .status, .details.outside]')"
assert_eq '">=3.9"' "$(row pypi.example-app .details.requires_python)"

# Nothing newer inside: current, and the new series still there.
json_edit "$versions" 'data["pypi"]["example-app"]["version"] = "1.4.0"'
assert_exit 0 latest --out "$report"
assert_eq '["1.4.0","current","2.0.0"]' "$(row pypi.example-app '[.latest, .status, .details.outside.latest]')"

# A pin outside its constraint already is not searched inside it.
json_edit "$versions" 'data["pypi"]["example-app"]["version"] = "2.0.0"'
assert_exit 0 latest --out "$report"
assert_eq '["2.0.0","current",null]' "$(row pypi.example-app '[.latest, .status, .details.outside]')"

# An adapter with one version only: the row stays, unsearchable.
json_edit "$versions" 'data["pypi"]["example-app"]["version"] = "1.0.0"'
json_edit "$versions" 'data["desktop_packages"]["example-app"]["minimum_version"] = "1.1.0"'
declare_latest \
  "{\"component\":\"example-app\",\"id\":\"desktop_packages.example-app\",\"adapter\":\"apt-index\",\"at\":\"desktop_packages.example-app\",\"base\":\"$url/apt\",\"package\":\"example-app\"}"
cat >"$www/apt/dists/stable/main/binary-amd64/Packages" <<'EOF'
Package: example-app
Version: 2.1.0
Architecture: amd64
Filename: pool/main/e/example-app/example-app_2.1.0_amd64.deb
Size: 200
SHA256: 3f79bb7b435b05321651daefd374cdc681dc06faa65e374e38337b88ca046dea
EOF
assert_exit 0 latest --out "$report"
assert_eq '["2.1.0","unsearchable"]' "$(row desktop_packages.example-app '[.latest, .details.within]')"
