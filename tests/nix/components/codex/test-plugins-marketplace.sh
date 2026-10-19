# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# A Codex plugin from a Git marketplace on GitHub: an entry with
# marketplace = "OWNER/REPO" makes `dotsteward agents install` add the
# marketplace with `codex plugin marketplace add OWNER/REPO` when
# `codex plugin marketplace list --json` does not list it under the spec's
# marketplace name, before the plugin is added. Both modes verify that the
# listed marketplace comes from that repository; check never adds anything.
# Codex refreshes configured Git marketplaces itself, so the entry needs no
# update switch. Invalid marketplace values fail the evaluation.
# shellcheck source=tests/nix/components/codex/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/codex/helpers.sh"

codex_hermetic_path
ds_use_stubs codex

spec=example-plugin@example-market
repo=example-org/example-market
cache=$HOME/.codex/plugins/cache/example-market/example-plugin

agents() {
  codex_cli "$inst" agents "$1" --profile workstation
}

inst=$(codex_instance marketplace '["x86_64-linux"]' "method = \"external\"
options = { plugins = [{ spec = \"$spec\", marketplace = \"$repo\" }] }")
codex_mirror "$inst"
mkdir -p "$HOME/.codex/skills" "$HOME/.agents/skills"

# --- check never adds the marketplace ----------------------------------------------------

before=$(codex_home_state)
assert_exit 1 agents check
assert_contains "$DS_STDERR" "codex marketplace example-market ($repo) is not added; run 'dotsteward agents install --profile workstation'"
assert_call_count 0 codex 'plugin marketplace add*'
assert_call_count 0 codex 'plugin add*'
assert_eq "$before" "$(codex_home_state)" "check changes nothing"

# --- install adds the marketplace, then the plugin ---------------------------------------

ds_stub_set codex plugin-version 1.0.0
assert_exit 0 agents install
assert_contains "$DS_STDOUT" "codex marketplace example-market: adding $repo with codex plugin marketplace add"
assert_contains "$DS_STDOUT" "codex marketplace example-market ($repo) verified"
assert_contains "$DS_STDOUT" "codex plugin $spec 1.0.0 verified"
assert_call_count 1 codex "plugin marketplace add $repo"
assert_call_count 1 codex "plugin add $spec"
assert_json "$cache/1.0.0/.codex-plugin/plugin.json" '.version == "1.0.0"'

# Present: nothing is added again, check passes.
assert_exit 0 agents install
assert_exit 0 agents check
assert_contains "$DS_STDOUT" "codex marketplace example-market ($repo) verified"
assert_call_count 1 codex "plugin marketplace add $repo"

# --- the listed marketplace must come from the repository ---------------------------------

# market NAME SOURCE: `codex plugin marketplace list --json` shows NAME from
# the Git source SOURCE.
market() {
  jq -cn --arg name "$1" --arg source "$2" \
    '{ marketplaces: [{ name: $name, root: "/synthetic/\($name)", marketplaceSource: { sourceType: "git", source: $source } }] }' |
    ds_stub_set codex marketplaces -
}

# Codex records the clone URL; the trailing .git and letter case do not matter.
market example-market https://github.com/Example-Org/example-market
assert_exit 0 agents check
assert_contains "$DS_STDOUT" "codex marketplace example-market ($repo) verified"

market example-market https://github.com/other-org/example-market.git
for mode in check install; do
  assert_exit 1 agents "$mode"
  assert_contains "$DS_STDERR" "codex marketplace example-market is added from https://github.com/other-org/example-market.git, not from github $repo"
done
assert_call_count 1 codex "plugin marketplace add $repo"

jq -cn '{ marketplaces: [{ name: "example-market", root: "/synthetic/local", marketplaceSource: { sourceType: "local", source: "/synthetic/local" } }] }' |
  ds_stub_set codex marketplaces -
assert_exit 1 agents check
assert_contains "$DS_STDERR" "codex marketplace example-market is added from /synthetic/local, not from github $repo"

# A repository whose manifest names another marketplace is refused after the add.
rm -rf -- "$DS_STUB_STATE/codex"
ds_stub_set codex marketplace-name other-market
assert_exit 1 agents install
assert_contains "$DS_STDERR" "codex plugin marketplace add $repo did not add the marketplace example-market"
assert_call_count 0 codex "plugin add $spec"

# --- entries without marketplace never touch marketplaces ---------------------------------

rm -rf -- "$DS_STUB_STATE/codex" "$HOME/.codex/plugins"
inst=$(codex_instance plain '["x86_64-linux"]' "method = \"external\"
options = { plugins = [{ spec = \"$spec\" }] }")
codex_mirror "$inst"
assert_exit 0 agents install
assert_call_count 0 codex 'plugin marketplace*'
assert_call_count 1 codex "plugin add $spec"

# --- invalid marketplace values ------------------------------------------------------------

username() {
  printf '(homeOf (%s) "x86_64-linux" "workstation").home.username' "$(codex_expr "$1")"
}
invalid=$(codex_instance invalid-marketplace '["x86_64-linux"]' 'options = { plugins = [
  { spec = "alpha@market", marketplace = "not a repository" },
  { spec = "beta@market", marketplace = 7 },
  { spec = "gamma@shared", marketplace = "first-org/shared" },
  { spec = "delta@shared", marketplace = "second-org/shared" },
] }')
assert_inst_fails "$(username "$invalid")" \
  "Failed assertions:" \
  '- dotsteward: component codex: options.plugins[0].marketplace must be a GitHub repository OWNER/REPO, got "not a repository"' \
  "- dotsteward: component codex: options.plugins[1].marketplace must be a GitHub repository OWNER/REPO, got 7" \
  '- dotsteward: component codex: options.plugins[3].marketplace is "second-org/shared" but options.plugins[2] adds the marketplace shared from "first-org/shared"'
