# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The whole maintenance transaction, as the update and maintain skills run
# it ([gate] I1): update prepare records the base, the gate proves the
# candidate tree, the change is committed, update status reports both
# records, update publish ships the commit and fast-forwards the canonical
# checkout. The gate runs for real against the nix and curl stubs; its
# static, pins and probes commands are fakes (they have suites of their
# own). A validation made with a framework override is never published.
# shellcheck source=tests/cli/update/helpers.sh
source "$DS_REPO_ROOT/tests/cli/update/helpers.sh"

ds_use_stubs nix curl gh
serve_cache

# A copy of the framework whose static, pins and probes commands succeed
# without looking at the instance.
fw=$DS_TEST_ROOT/framework
mkdir -p "$fw/modules/components"
cp -R "$DS_REPO_ROOT/cli" "$DS_REPO_ROOT/schema" "$DS_REPO_ROOT/VERSION" "$fw/"
find "$fw/cli" -name __pycache__ -prune -exec rm -rf {} +
for command in static pins probes; do
  printf '#!/usr/bin/env bash\n# summary: Fake %s command of the update tests\nprintf "fake %s\\n"\n' \
    "$command" "$command" >"$fw/cli/commands/$command.sh"
  chmod 0755 "$fw/cli/commands/$command.sh"
done

ds() {
  "$fw/cli/dotsteward" --instance "$up_inst" "$@" </dev/null
}

canon=$HOME/instance
git clone -q "$up_bare" "$canon"
git -C "$canon" remote set-url origin "$UP_REMOTE"

# --- update scope: a pin refresh ------------------------------------------------------

assert_exit 0 ds update prepare --official-sources-only
base=$(jq -r .base_oid "$up_candidate")
assert_eq "$(head_oid)" "$base"

printf '{\n  "schema_version": "1.0",\n  "refreshed": true\n}\n' >"$up_inst/versions.lock.json"
assert_exit 0 ds gate
assert_json "$up_validation" '.result == "passed" and .scope == "update" and .base_oid == "'"$base"'"'
tree=$(jq -r .tree_oid "$up_validation")

assert_exit 0 ds update status --json
assert_eq "$base" "$(jq -r .candidate.base_oid <<<"$DS_STDOUT")"
assert_eq "$tree" "$(jq -r .validation.tree_oid <<<"$DS_STDOUT")"
assert_eq "preflight static pins flake-check cli-probes" \
  "$(jq -r '.validation.step_seconds | keys_unsorted | join(" ")' <<<"$DS_STDOUT")"

# Publishing before the commit is refused: the tree is not committed.
assert_exit 1 ds update publish
assert_eq "[dotsteward] ERROR: update publish needs a committed, clean candidate" "$DS_STDERR"

commit_all "$UP_UPDATE_SUBJECT"
assert_eq "$tree" "$(head_tree)"
reset_logs
assert_exit 0 ds update publish
assert_eq "$(head_oid)" "$(remote_oid)"
assert_eq "$(head_oid)" "$(git -C "$canon" rev-parse HEAD)"
assert_contains "$DS_STDOUT" "[dotsteward] published $(head_oid) to main without force"
# Publishing never builds anything.
assert_call_count 0 nix

# --- maintain scope: a framework override is never published -----------------------------

assert_exit 0 ds update prepare --official-sources-only --scope maintain
base=$(head_oid)
printf 'maintained\n' >>"$up_inst/docs/guide.md"
assert_exit 0 ds gate --scope maintain --framework-override "path:$DS_TEST_ROOT/candidate-framework"
commit_all "docs: maintain the guide"
assert_exit 1 ds update publish --scope maintain
assert_eq "[dotsteward] ERROR: the validation used the framework override path:$DS_TEST_ROOT/candidate-framework; run 'dotsteward gate --scope maintain' without an override first" \
  "$DS_STDERR"
assert_eq "$base" "$(remote_oid)"

# The gate without the override runs again (the override is part of the
# memo key) and its record can be published.
assert_exit 0 ds gate --scope maintain
assert_not_contains "$DS_STDOUT" '"memo":true'
assert_json "$up_validation" '.framework_override == null and .tree_oid == "'"$(head_tree)"'"'
assert_exit 0 ds update publish --scope maintain
assert_eq "$(head_oid)" "$(remote_oid)"
assert_eq "$(head_oid)" "$(git -C "$canon" rev-parse HEAD)"

# Run again: already published.
assert_exit 0 ds update publish --scope maintain
assert_eq "[dotsteward] main is already $(head_oid) on the remote; nothing to push" "$DS_STDOUT"
# The canonical checkout already holds the published commit: nothing to say.
assert_eq "" "$DS_STDERR"

# --- a validation made for the other scope ------------------------------------------------
# Scope is not part of the memo key, so a plain gate in the publish scope
# answers from the memo and keeps the recorded scope; the refusal hint
# therefore asks for --force, which runs the gate again and records the
# publish scope.

assert_exit 0 ds update prepare --official-sources-only --scope maintain
base=$(head_oid)
printf '{\n  "schema_version": "1.0",\n  "maintained": true\n}\n' >"$up_inst/versions.lock.json"
assert_exit 0 ds gate --scope update
commit_all "chore: maintain the versions lock"
scope_hint="[dotsteward] ERROR: the validation was made for the update scope, not maintain; run 'dotsteward gate --scope maintain --force' first"
assert_exit 1 ds update publish --scope maintain
assert_eq "$scope_hint" "$DS_STDERR"

# The plain gate is a memo hit and leaves the update scope in the record.
assert_exit 0 ds gate --scope maintain
assert_contains "$DS_STDOUT" '"memo":true'
assert_json "$up_validation" '.scope == "update"'
assert_exit 1 ds update publish --scope maintain
assert_eq "$scope_hint" "$DS_STDERR"
assert_eq "$base" "$(remote_oid)"

# The command the hint names records the publish scope; publish then ships.
assert_exit 0 ds gate --scope maintain --force
assert_not_contains "$DS_STDOUT" '"memo":true'
assert_json "$up_validation" '.result == "passed" and .scope == "maintain" and .tree_oid == "'"$(head_tree)"'"'
assert_exit 0 ds update publish --scope maintain
assert_eq "$(head_oid)" "$(remote_oid)"
assert_eq "$(head_oid)" "$(git -C "$canon" rev-parse HEAD)"
