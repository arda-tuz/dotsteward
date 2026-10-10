# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Tracking of Codex plugins: a plugin of [components.codex] options that
# names a tracking entry (trackAt, with watched) becomes a git-compare review
# row of its marketplace in the manifest, with every method, which
# `dotsteward pins check` accepts; a plugin without one is not tracked; an
# invalid tracking entry fails the evaluation with every problem listed,
# with the same messages as the claude-code plugins option.
# shellcheck source=tests/nix/components/codex/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/codex/helpers.sh"

revision=0123456789abcdef0123456789abcdef01234567

# manifest INSTANCE_DIR: the x86_64-linux manifest, store contexts discarded.
manifest() {
  inst_json "storeless (homeOf ($(codex_expr "$1")) \"x86_64-linux\" \"workstation\").dotsteward.manifest"
}

tracked=$(codex_instance tracked '["x86_64-linux"]' 'method = "external"
options = { plugins = [
  { spec = "example-plugin@example-market", minimumAt = "agent_tools.example-plugin", trackAt = "agent_tools.example-plugin", watched = ["plugins/example-plugin/.+"] },
  { spec = "other-plugin@example-market" },
] }')
codex_lock_set "$tracked" agent_tools.example-plugin \
  "{\"minimum_version\": \"1.2.0\", \"source\": \"https://github.com/example-org/example-marketplace\", \"observed_marketplace_revision\": \"$revision\"}"
result=$(manifest "$tracked")
json_check "$result" '[.pins.latest[] | select(.component == "codex")]' "$(jq -cS . <<'EOF'
[
  {
    "component": "codex",
    "id": "agent_tools.example-plugin",
    "adapter": "git-compare",
    "at": "agent_tools.example-plugin",
    "repo_at": ".source",
    "revision_at": ".observed_marketplace_revision",
    "watched": ["plugins/example-plugin/.+"]
  }
]
EOF
)"

# With the default method the row follows the release pins, and the pins
# engine accepts the declarations (with the flake.nix and flake.lock of the
# inputs the minimal lock records).
default=$(codex_instance default '["x86_64-linux"]' 'options = { plugins = [
  { spec = "example-plugin@example-market", trackAt = "agent_tools.example-plugin", watched = ["plugins/example-plugin/.+"] },
] }')
codex_lock_set "$default" agent_tools.example-plugin \
  "{\"source\": \"https://github.com/example-org/example-marketplace\", \"observed_marketplace_revision\": \"$revision\"}"
json_check "$(manifest "$default")" '[.pins.latest[] | select(.component == "codex") | [.id, .adapter]]' \
  '[["agent_tools.codex.linux","github-release"],["agent_tools.example-plugin","git-compare"]]'
cp -- "$nix_instance_fixtures/example/flake.nix" "$nix_instance_fixtures/example/flake.lock" "$default/"
codex_mirror "$default"
assert_exit 0 codex_cli "$default" pins check

# --- Invalid tracking entries ---------------------------------------------------------

username() {
  printf '(homeOf (%s) "x86_64-linux" "workstation").home.username' "$(codex_expr "$1")"
}

invalid=$(codex_instance invalid '["x86_64-linux"]' 'options = { plugins = [
  { spec = "alpha@market", trackAt = "agent_tools.missing", watched = ["plugins/.+"] },
  { spec = "beta@market", trackAt = "agent_tools.half" },
  { spec = "gamma@market", watched = ["plugins/.+"] },
  { spec = "delta@market", trackAt = 4, watched = "plugins/.+" },
  { spec = "epsilon@market", trackAt = "agent_tools.scalar", watched = ["plugins/.+"] },
] }')
codex_lock_set "$invalid" agent_tools.half '{"source": "https://example.com/not-github", "observed_marketplace_revision": "abc"}'
codex_lock_set "$invalid" agent_tools.scalar '"1.0.0"'
assert_inst_fails "$(username "$invalid")" \
  "Failed assertions:" \
  "- dotsteward: component codex: options.plugins[0].trackAt: versions.lock.json lacks agent_tools.missing" \
  "- dotsteward: component codex: options.plugins[1].trackAt: versions.lock.json agent_tools.half.source must be a GitHub repository URL https://github.com/OWNER/REPO" \
  "- dotsteward: component codex: options.plugins[1].trackAt: versions.lock.json agent_tools.half.observed_marketplace_revision must be a 40-digit commit" \
  "- dotsteward: component codex: options.plugins[1].trackAt needs watched, a non-empty list of path patterns" \
  "- dotsteward: component codex: options.plugins[2].watched needs trackAt" \
  "- dotsteward: component codex: options.plugins[3].trackAt must be a versions.lock.json path, got 4" \
  "- dotsteward: component codex: options.plugins[3].watched must be a list of path patterns" \
  "- dotsteward: component codex: options.plugins[4].trackAt: versions.lock.json agent_tools.scalar must be an entry with source and observed_marketplace_revision"
