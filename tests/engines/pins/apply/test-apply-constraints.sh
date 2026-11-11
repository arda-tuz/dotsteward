# shellcheck shell=bash
# The version constraint of a component is a range, not a stop: a pin inside it moves to a newer
# version inside it with no person asked, and a newer version outside it waits as
# `pins-constrained`, naming the constraint, its reason and the newest version, so the owner can
# decide. A pin the constraint does not describe (its version is outside it already) waits too.
# The shared lock goes to every machine, so the constraint of a platform layer counts as soon as a
# machine of the instance runs that platform, and not before.
# shellcheck source=tests/engines/pins/apply/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/apply/helpers.sh"

apply_world
digest=$(printf '%064d' 7)
url_of() {
  printf 'https://downloads.example.invalid/example-release/v%s/example-release-linux-x64.tar.gz' "$1"
}
release_row() {
  local status=update
  [[ ${1%%.*} == "${2%%.*}" ]] || status=review
  row agent_tools.example-release github-release "$1" "$2" "$status" \
    '{"tag":"v'"$2"'","asset":"example-release-linux-x64.tar.gz","size":4242,"sha256":"'"$digest"'","url":"'"$(url_of "$2")"'"}'
}
pinned() {
  json_get "$versions" '.agent_tools["example-release"].minimum_version' | tr -d '"'
}
constrained_item() {
  jq -c '[.items[] | select(.code == "pins-constrained" and .id == "agent_tools.example-release")] | first // empty' \
    "$state/review.json"
}

cat >>"$inst/workstation.toml" <<'TOML'

[components.example-release]
enable = true
version = "4.*"
reason = "the plugins of this machine speak the 4.x protocol"
TOML
git -C "$inst" add -A
git -C "$inst" commit -q -m "a constraint"

# Inside the constraint: the pin moves, nobody is asked.
rows "$(release_row 4.0.0 4.1.0)"
assert_exit 0 apply --latest "$rows"
assert_eq 4.1.0 "$(pinned)"
assert_eq "" "$(item_codes 2>/dev/null || true)"
assert_exit 0 pins check

# A newer major outside it: the pin stays, the item names the constraint, why, and the newest version.
before=$(tree_state)
rows "$(release_row 4.1.0 5.0.0)"
assert_exit 3 apply --latest "$rows"
assert_eq "$before" "$(tree_state)"
assert_eq "pins-constrained agent_tools.example-release" "$(item_codes)"
item=$(constrained_item)
assert_contains "$item" '"latest":"5.0.0"'
assert_contains "$item" "version = '4.*'"
assert_contains "$item" "the plugins of this machine speak the 4.x protocol"

# --- the platform layer ----------------------------------------------------------------------
# A platform file narrows the constraint; no machine runs that platform yet, so it is not in force.
mkdir -p "$inst/platforms" "$inst/hosts"
cat >"$inst/platforms/ubuntu-22.04.toml" <<'TOML'
schema_version = 1

[components.example-release]
version = "4.1.*"
reason = "the older release of this platform has only the 4.1 runtime"
TOML
git -C "$inst" add -A
git -C "$inst" commit -q -m "a platform constraint"
json_edit "$versions" 'data["agent_tools"]["example-release"]["minimum_version"] = "4.1.0"'
rows "$(release_row 4.1.0 4.2.0)"
assert_exit 0 apply --plan --latest "$rows" --json
assert_not_contains "$DS_STDOUT" "pins-constrained"

# A machine of that platform: the shared lock goes to it too, so its constraint holds the pin.
printf 'schema_version = 1\nplatform = "ubuntu-22.04"\n' >"$inst/hosts/example-old.toml"
printf 'schema_version = 1\nplatform = "ubuntu-24.04"\n' >"$inst/hosts/example-new.toml"
git -C "$inst" add -A
git -C "$inst" commit -q -m "two machines"
assert_exit 0 apply --plan --latest "$rows" --json
assert_contains "$DS_STDOUT" "pins-constrained"
assert_contains "$DS_STDOUT" "4.1.*"
assert_contains "$DS_STDOUT" "platforms/ubuntu-22.04.toml"
assert_contains "$DS_STDOUT" "example-old"
rows "$(release_row 4.1.0 4.1.5)"
assert_exit 0 apply --plan --latest "$rows" --json
assert_not_contains "$DS_STDOUT" "pins-constrained"

# A pin the constraint does not describe: its version is outside it already, so a person decides.
json_edit "$versions" 'data["agent_tools"]["example-release"]["minimum_version"] = "5.0.0"'
rm -f -- "$inst/platforms/ubuntu-22.04.toml"
rows "$(release_row 5.0.0 5.1.0)"
assert_exit 0 apply --plan --latest "$rows" --json
assert_contains "$DS_STDOUT" "pins-constrained"

# A constraint that is no series of versions is refused, never silently ineffective.
for refused in '^4' '>=4' '4.x' '4*'; do
  git -C "$inst" checkout -q -- workstation.toml
  python3 - "$inst/workstation.toml" "$refused" <<'PY'
import sys
path, value = sys.argv[1:]
text = open(path, encoding="utf-8").read().replace('version = "4.*"', f'version = "{value}"')
open(path, "w", encoding="utf-8").write(text)
PY
  assert_exit 2 apply --plan --latest "$rows" --json
  assert_contains "$DS_STDERR" "components.example-release.version"
done
git -C "$inst" checkout -q -- workstation.toml
