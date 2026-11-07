# shellcheck shell=bash
# `pins apply --plan`: every row status lands where the design says, and
# nothing is written: not the instance, not the state root, no tool runs.
# shellcheck source=tests/engines/pins/apply/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/apply/helpers.sh"

apply_world

rows \
  "$(row agent_tools.example-release github-release 4.0.0 4.1.0 update '{"tag":"v4.1.0","url":"https://downloads.example.invalid/example-release/v4.1.0/example-release-linux-x64.tar.gz","size":10,"sha256":"'"$(printf '%064d' 1)"'"}')" \
  "$(row flake_inputs.example-term github-release 1.2.0 1.3.0 update '{"tag":"v1.3.0"}')" \
  "$(row npm.example-cli npm 2.0.0 2.1.0 update '{"git_head":null}')" \
  "$(row agent_tools.example-compat npm 1.0.0 1.0.1 update)" \
  "$(row agent_tools.example-plain npm 1.0.0 2.0.0 review)" \
  "$(row agent_tools.example-market git-compare 111111111111 aaaaaaaaaaaa review '{"head":"'"$(printf 'a%.0s' {1..40})"'","changed_paths":["plugin.json"]}')" \
  "$(row example_watch git-compare 222222222222 bbbbbbbbbbbb review '{"changed_paths":["README.md"]}')" \
  "$(row desktop_packages.example-desktop official-manifest 1.5.0 1.6.0 held '{"note":"waits for a device test"}')" \
  "$(row skills.example-manual manual snapshot "" manual '{"note":"compare by hand"}')" \
  "$(row pypi.example-tool pypi 1.0.0 "" error '{"error":"the index answered 500"}')"

before=$(tree_state)
assert_exit 0 apply --latest "$rows" --plan --json

assert_eq "$before" "$(tree_state)" "--plan changed the instance"
assert_eq "" "$(git -C "$inst" status --porcelain)" "--plan changed the work tree"
assert_eq "" "$(find "$state" -mindepth 1)" "--plan wrote to the state root"
assert_eq "" "$(<"$FAKE_NIX_STATE/calls")" "--plan ran nix"

plan=$DS_STDOUT
assert_eq true "$(jq -c .plan <<<"$plan")"
assert_eq '["download:agent_tools.example-release","flake:example-term","npm:packages/example-bundle"]' \
  "$(jq -c '[.groups[].group] | sort' <<<"$plan")"
assert_eq '["planned"]' "$(jq -c '[.groups[].outcome] | unique' <<<"$plan")"
assert_eq '["pins-constrained agent_tools.example-compat","pins-no-writer agent_tools.example-plain","pins-review example_watch"]' \
  "$(jq -c '[.items[] | "\(.code) \(.id)"] | sort' <<<"$plan")"
assert_eq '["error pypi.example-tool","held desktop_packages.example-desktop","manual skills.example-manual","self-updating agent_tools.example-market"]' \
  "$(jq -c '[.lines[] | "\(.status) \(.id)"] | sort' <<<"$plan")"

# The plain output names what would happen.
assert_exit 0 apply --latest "$rows" --plan
assert_contains "$DS_STDOUT" "would move"
assert_contains "$DS_STDOUT" "agent_tools.example-release"
assert_eq "$before" "$(tree_state)" "--plan changed the instance"
