# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# dotsteward context shows, for each component, the updater the instance names and the update
# command the component declares (self_update of the manifest mirror, null without one), so an
# agent can tell whether updater = "self" would start anything before it writes it.
# shellcheck source=tests/cli/context/helpers.sh
source "$DS_REPO_ROOT/tests/cli/context/helpers.sh"

export DOTSTEWARD_PLATFORM=linux
inst=$DS_TEST_ROOT/instances/rich
make_rich_instance "$inst"
python3 - "$inst/workstation.toml" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace('[components.codex]\nenable = true\n', '[components.codex]\nenable = true\nupdater = "self"\n', 1)
open(path, "w", encoding="utf-8").write(text)
PY
write_mirror "$inst"
mirror=$inst/.dotsteward/manifest.$(runtime_system).json
jq '(.components[] | select(.name == "codex")).self_update = {command: ["codex", "update"], version: ["codex", "--version"]}' \
  "$mirror" >"$mirror.new"
mv -- "$mirror.new" "$mirror"

doc=$(context_json "$inst")
printf '%s\n' "$doc" >"$DS_TEST_ROOT/context.json"
validate_schema "$DS_TEST_ROOT/context.json"
assert_eq '{"updater":"self","self_update":{"command":["codex","update"],"version":["codex","--version"]}}' \
  "$(jq -c '.components[] | select(.name == "codex") | {updater, self_update}' <<<"$doc")"
assert_eq '{"updater":null,"self_update":null}' \
  "$(jq -c '.components[] | select(.name == "vscode") | {updater, self_update}' <<<"$doc")"

# The text form says the same, one line per fact.
assert_exit 0 bash -c "cd '$inst' && '$context_framework/cli/dotsteward' context"
assert_contains "$DS_STDOUT" "[dotsteward] components.codex.updater: self"
assert_contains "$DS_STDOUT" "[dotsteward] components.codex.self_update.command: codex, update"
assert_contains "$DS_STDOUT" "[dotsteward] components.vscode.self_update: none"
