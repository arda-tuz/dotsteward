# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and settings_* variables come from the harness and helpers.sh
# The status --json schema and the exit codes of every command: 0 ok, 1
# verify found rows that did not converge, 2 errors (error rows refuse every
# writing command before any write; an invalid buffer fails every command),
# 3 flush left entries waiting for a decision.
# shellcheck source=tests/engines/settings/core/helpers.sh
source "$DS_REPO_ROOT/tests/engines/settings/core/helpers.sh"

settings_machines
a_home=$settings_work/A/home
assert_exit 0 lmf A apply

# status --json: one document with the original schema.
lmf A status --json >"$DS_TEST_ROOT/status.json"
assert_json "$DS_TEST_ROOT/status.json" 'keys == ["entries", "published_available", "repo_last_change", "schema_version"]'
assert_json "$DS_TEST_ROOT/status.json" '.schema_version == 1 and .published_available == true'
assert_json "$DS_TEST_ROOT/status.json" '.repo_last_change | keys == ["date", "oid", "subject"] and (.oid | test("^[0-9a-f]{40}$")) and .subject == "chore: seed local maintained settings"'
assert_json "$DS_TEST_ROOT/status.json" \
  '[.entries[] | keys] | unique == [["base", "error", "id", "kind", "live", "live_modified", "needs_decision", "note", "path", "repo", "state", "target"]]'
assert_json "$DS_TEST_ROOT/status.json" '[.entries[].id] == ["alpha-status", "alpha-env-model", "alpha-env-limit", "alpha-script", "beta-threads", "beta-onboarding", "beta-theme", "beta-plugins", "beta-mode", "beta-ui", "gamma-guideline"]'
assert_json "$DS_TEST_ROOT/status.json" '.entries[0] | .kind == "key" and .target == "alpha" and .path == ["statusLine"] and .note == "status line command and refresh interval" and .state == "in-sync" and .needs_decision == false and .error == null and .live == .repo and .base == .repo and (.live_modified | test("^[0-9-]{10}T[0-9:]{8}Z$"))'
assert_json "$DS_TEST_ROOT/status.json" '.entries[3] | .kind == "file" and .target == null and .path == "~/.config/alpha/status.sh" and (.live | keys) == ["mode", "sha256"] and .note == ""'
assert_json "$DS_TEST_ROOT/status.json" '.entries[6] | .repo == {"absent": true} and .live == {"absent": true}'
assert_json "$DS_TEST_ROOT/status.json" '.entries[10] | .state == "deferred" and .live == null and .base == null and .live_modified == null and .repo == {"value": "short"}'
# The text form: one line per entry and a summary.
assert_exit 0 lmf A status
assert_eq 12 "$(wc -l <<<"$DS_STDOUT")"
assert_contains "$DS_STDOUT" "summary: deferred=1, in-sync=10"
assert_contains "$(grep '^alpha-script ' <<<"$DS_STDOUT")" " file "

# Everything converged: every command succeeds; resolve refuses an entry
# that needs no decision and an unknown id.
for command in status apply flush reconcile verify; do
  assert_exit 0 lmf A "$command"
done
assert_exit 2 lmf A resolve beta-threads --local
assert_exit 2 lmf A resolve no-such-id --remote
assert_exit 2 lmf A untrack no-such-id
# Usage errors.
assert_exit 2 lmf A resolve beta-threads
assert_exit 2 lmf A no-such-command
assert_exit 0 settings --help
assert_contains "$DS_STDOUT" "track-file"
assert_exit 0 "$DS_REPO_ROOT/cli/dotsteward" --help
assert_contains "$(grep '^  settings ' <<<"$DS_STDOUT")" "settings buffer"

# A pending decision: flush exits 3, verify passes with a notice, apply
# leaves it alone.
json_edit "$a_home/.config/alpha/settings.json" 'del data["env"]["SEARCH_LIMIT"]'
assert_eq local-deleted "$(state_of A alpha-env-limit)"
assert_exit 3 lmf A flush
assert_contains "$DS_STDERR" "alpha-env-limit"
assert_exit 0 lmf A verify
assert_exit 0 lmf A apply
assert_eq '<absent>' "$(json_get "$a_home/.config/alpha/settings.json" env.SEARCH_LIMIT)"
assert_exit 0 lmf A resolve alpha-env-limit --remote
assert_eq '"5"' "$(json_get "$a_home/.config/alpha/settings.json" env.SEARCH_LIMIT)"

# A not converged row (remote-changed): verify exits 1.
set_line "$settings_work/A/repo/local-maintained-files/buffer.toml" 'value = 10' 'value = 12'
assert_eq remote-changed "$(state_of A beta-threads)"
assert_exit 1 lmf A verify
assert_contains "$DS_STDERR" "beta-threads"
git -C "$settings_work/A/repo" checkout -q -- local-maintained-files/buffer.toml

# Error rows (a symlinked target): status shows them, every writing command
# refuses before any write, verify exits 1, track refuses that target only.
beta=$a_home/.config/beta/config.toml
mv "$beta" "$beta.real"
ln -s "$beta.real" "$beta"
json_edit "$a_home/.config/alpha/settings.json" 'data["env"]["SEARCH_LIMIT"] = "6"'
assert_exit 0 lmf A status
assert_contains "$DS_STDOUT" "error"
assert_eq error "$(state_of A beta-threads)"
assert_eq local-changed "$(state_of A alpha-env-limit)"
for command in apply flush; do
  assert_exit 2 lmf A "$command"
  assert_contains "$DS_STDERR" "beta-threads"
done
assert_exit 2 lmf A resolve alpha-env-limit --local
assert_eq '"5"' "$(buffer_get A alpha-env-limit)" "flush wrote despite error rows"
assert_exit 0 lmf A reconcile
assert_exit 1 lmf A verify
assert_exit 2 lmf A track --id beta-new --target beta --key extra
assert_exit 0 lmf A track --id alpha-new --target alpha --key extra
assert_exit 0 lmf A untrack alpha-new
rm "$beta"
mv "$beta.real" "$beta"
json_edit "$a_home/.config/alpha/settings.json" 'data["env"]["SEARCH_LIMIT"] = "5"'

# An invalid buffer fails every command with 2, verify included.
buffer=$settings_work/A/repo/local-maintained-files/buffer.toml
cp "$buffer" "$DS_TEST_ROOT/buffer.good"
sed -i 's/^schema_version = 1$/schema_version = 2/' "$buffer"
for command in status apply flush reconcile verify; do
  assert_exit 2 lmf A "$command"
  assert_contains "$DS_STDERR" "schema_version"
done
assert_exit 2 lmf A track --id x1 --target alpha --key x
assert_exit 2 lmf A resolve beta-threads --remote
cp "$DS_TEST_ROOT/buffer.good" "$buffer"
printf '[[entries]]\nid = "dup"\ntarget = "alpha"\nkey = ["statusLine", "type"]\nvalue = "x"\n' >>"$buffer"
assert_exit 2 lmf A status
assert_contains "$DS_STDERR" "alpha-status"
cp "$DS_TEST_ROOT/buffer.good" "$buffer"
printf 'this is = not toml\n' >>"$buffer"
assert_exit 2 lmf A status
assert_contains "$DS_STDERR" "buffer.toml"
cp "$DS_TEST_ROOT/buffer.good" "$buffer"
rm "$buffer"
assert_exit 2 lmf A status
assert_contains "$DS_STDERR" "buffer.toml"
