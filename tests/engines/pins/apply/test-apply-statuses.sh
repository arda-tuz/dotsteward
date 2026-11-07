# shellcheck shell=bash
# The report: held and manual rows are report lines, an error row skips the group
# it belongs to and the others go on, a failing group does not block the others,
# and the marketplace rows that update themselves (T7-b) are one line each.
# shellcheck source=tests/engines/pins/apply/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/apply/helpers.sh"

apply_world
digest=$(printf '%064d' 7)
release_row=$(row agent_tools.example-release github-release 4.0.0 4.1.0 update '{"tag":"v4.1.0","size":1,"sha256":"'"$digest"'","url":"https://downloads.example.invalid/example-release/v4.1.0/example-release-linux-x64.tar.gz"}')

# Held and manual: no review item, no write.
rows \
  "$(row desktop_packages.example-desktop official-manifest 1.5.0 1.6.0 held '{"note":"waits for a device test"}')" \
  "$(row skills.example-manual manual snapshot "" manual '{"note":"compare by hand"}')" \
  "$(row agent_tools.example-market git-compare 111111111111 aaaaaaaaaaaa review '{"changed_paths":["plugin.json"]}')"
before=$(tree_state)
assert_exit 0 apply --latest "$rows"
assert_eq "$before" "$(tree_state)"
assert_contains "$DS_STDOUT" "held"
assert_contains "$DS_STDOUT" "waits for a device test"
assert_contains "$DS_STDOUT" "compare by hand"
assert_contains "$DS_STDOUT" "agent_tools.example-market"
[[ ! -e "$state/review.json" ]] || ds_fail "unexpected $state/review.json"
assert_eq '{"held":1,"manual":1,"self-updating":1}' \
  "$(last_report '[.steps[] | select(.name == "rows") | .lines[].status] | group_by(.) | map({(.[0]): length}) | add')"

# A watched upstream path is an inspection, not a move.
rows "$(row example_watch git-compare 222222222222 bbbbbbbbbbbb review '{"changed_paths":["README.md","docs/usage.md"]}')"
assert_exit 3 apply --latest "$rows"
assert_eq "pins-review example_watch" "$(item_codes)"
assert_eq "$before" "$(tree_state)"
assert_contains "$(jq -c '.items[0].changed_paths' "$state/review.json")" "docs/usage.md"

# An error row: the rows of its group wait, the other groups move. Exit 6: the
# network failed, the run did what it could.
rows \
  "$(row npm.example-cli npm 2.0.0 "" error '{"error":"the registry answered 500"}')" \
  "$(row npm_security_overrides.example-dep npm 1.0.1 1.0.2 update)" \
  "$release_row"
assert_exit 6 apply --latest "$rows" --json
summary=$DS_STDOUT
assert_eq '"4.1.0"' "$(json_get "$versions" '.agent_tools["example-release"].minimum_version')"
assert_eq '"1.0.1"' "$(json_get "$versions" '.agent_tools.npm_security_overrides["example-dep"].version')"
assert_eq "skipped" "$(jq -r '.groups[] | select(.group == "npm:packages/example-bundle") | .outcome' <<<"$summary")"
assert_contains "$(jq -c '.groups[] | select(.group == "npm:packages/example-bundle") | .error' <<<"$summary")" "npm.example-cli"
assert_eq '["error npm.example-cli"]' "$(jq -c '[.lines[] | "\(.status) \(.id)"]' <<<"$summary")"
assert_exit 0 pins check
git -C "$inst" reset -q --hard

# One channel input failed: the channel group moves together or not at all.
head=$(git -C "$github/example/nixpkgs" rev-parse main)
json_edit "$versions" 'data["flake_inputs"]["example-term"]["channel"] = "example-26.05"'
rows \
  "$(row flake_inputs.nixpkgs channel-head d93fc7d10ddf "${head:0:12}" update '{"channel":"example-26.05","head":"'"$head"'","newest_series":"example-26.05"}')" \
  "$(row flake_inputs.example-term channel-head 7031b8e52207 "" error '{"error":"cannot reach the remote"}')"
before=$(tree_state)
assert_exit 6 apply --latest "$rows"
assert_eq "$before" "$(tree_state)"
git -C "$inst" reset -q --hard

# A row of the runner: its error names the ids of its job.
rows \
  "$(row job-3 error "" "" error '{"error":"boom","ids":["npm.example-cli"]}')" \
  "$(row npm_security_overrides.example-dep npm 1.0.1 1.0.2 update)"
before=$(tree_state)
assert_exit 6 apply --latest "$rows"
assert_eq "$before" "$(tree_state)"

# A failing group: everything it touched is restored, the others move, exit 1.
printf 'example-term\n' >"$FAKE_NIX_STATE/fail-lock"
flake_before=$(sha256sum "$inst/flake.nix" "$inst/flake.lock")
rows "$(row flake_inputs.example-term github-release 1.2.0 1.3.0 update '{"tag":"v1.3.0"}')" "$release_row"
assert_exit 1 apply --latest "$rows"
assert_contains "$DS_STDERR" "flake:example-term"
assert_contains "$DS_STDERR" "HTTP error 504"
assert_eq "$flake_before" "$(sha256sum "$inst/flake.nix" "$inst/flake.lock")"
assert_eq '"1.2.0"' "$(json_get "$versions" '.flake_inputs["example-term"].version')"
assert_eq '"4.1.0"' "$(json_get "$versions" '.agent_tools["example-release"].minimum_version')"
assert_exit 0 pins check
rm -f -- "$FAKE_NIX_STATE/fail-lock"

# A row the instance no longer declares is a line, not a guess.
git -C "$inst" reset -q --hard
rows "$(row agent_tools.example-gone npm 1.0.0 1.1.0 update)"
before=$(tree_state)
assert_exit 0 apply --latest "$rows" --json
assert_eq '["undeclared agent_tools.example-gone"]' "$(jq -c '[.lines[] | "\(.status) \(.id)"]' <<<"$DS_STDOUT")"
assert_eq "$before" "$(tree_state)"

# A report that is not one is a broken input.
printf 'not json\n' >"$rows"
assert_exit 2 apply --latest "$rows"
assert_contains "$DS_STDERR" "$rows"
