# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# dotsteward doctor --redact (SPEC 6.2, 6.5): the shareable report. Home
# directories, usernames, the hostname, the remote (and its owner and
# repository), settings entry ids and target names, instance component names
# and their surfaces, and instance skill names become <redacted>, in the
# JSON document and in the human report; the checks and their statuses stay.
# Settings values are never printed, with or without --redact.
# shellcheck source=tests/cli/context/helpers.sh
source "$DS_REPO_ROOT/tests/cli/context/helpers.sh"

export DOTSTEWARD_PLATFORM=linux
use_fake_nix
inst=$DS_TEST_ROOT/instances/workstation
make_rich_instance "$inst"
write_state "$DOTSTEWARD_STATE_ROOT"
# A home-relative state root, so home paths appear in the report.
unset DOTSTEWARD_STATE_ROOT
mkdir -p "$HOME/.local/state/workstation"
cp -R "$DS_TEST_ROOT/state/." "$HOME/.local/state/workstation/"
hostname=$(python3 -c 'import socket; print(socket.gethostname())')

assert_exit 0 ds_cli --instance "$inst" doctor --json
plain=$DS_STDOUT
assert_contains "$plain" "$HOME"
assert_contains "$plain" alice
assert_contains "$plain" codex-model
assert_contains "$plain" example-term

leaks() {
  local text=$1 term
  for term in "$HOME" /home/alice /Users/alice dotsteward-test alice "$hostname" \
    git@github.com:alice/workstation.git '"workstation"' \
    codex-model term-theme term-font codex-config vscode-settings example-term \
    example-local example-notes example-review sentinel-value; do
    assert_not_contains "$text" "$term" "redacted report leaks [$term]"
  done
}

assert_exit 0 ds_cli --instance "$inst" doctor --json --redact
redacted=$DS_STDOUT
leaks "$redacted"
assert_eq true "$(jq -r .redacted <<<"$redacted")"
assert_eq '<redacted>' "$(jq -r .host.hostname <<<"$redacted")"
assert_eq '["<redacted>","<redacted>",false]' \
  "$(jq -c '.context.identity | [.check_username, .runtime_user, .runtime_matches_check]' <<<"$redacted")"
# Paths keep their shape: the home prefix and the repository token go.
assert_eq '<redacted>/.local/state/<redacted>' "$(jq -r .context.state.root <<<"$redacted")"
assert_eq '["<redacted>","<redacted>","<redacted>"]' "$(jq -c .context.settings.entry_ids <<<"$redacted")"
assert_eq '["<redacted>","<redacted>","<redacted>","<redacted>"]' "$(jq -c .context.settings.target_names <<<"$redacted")"
# Catalog components keep their names; instance components do not.
assert_eq '["shell","herdr","claude-code","codex","opencode-pi","vscode","<redacted>"]' \
  "$(jq -c '[.context.components[].name]' <<<"$redacted")"
assert_eq '[["<redacted>"],["<redacted>"]]' \
  "$(jq -c '.context.components[] | select(.source == "instance") | [.settings_targets, .commands]' <<<"$redacted")"
assert_eq '["<redacted>","<redacted>","<redacted>"]' "$(jq -c .context.skills.instance_skill_names <<<"$redacted")"
# The checks are the same checks, with the same statuses.
assert_eq "$(jq -c '[.status, [.checks[] | [.id, .status]]]' <<<"$plain")" \
  "$(jq -c '[.status, [.checks[] | [.id, .status]]]' <<<"$redacted")"
# The remote goes as a whole; public facts stay.
assert_eq '"<redacted>"' "$(jq -c .context.instance.remote <<<"$redacted")"
assert_eq '["github:example-org/dotsteward","v1.2.0"]' \
  "$(jq -c '[.context.framework.upstream, .context.framework.track]' <<<"$redacted")"
assert_eq '["feat","fix","perf","refactor","docs","chore","test","build","ci","style","revert"]' \
  "$(jq -c .context.commit.conventional_types <<<"$redacted")"

# The human report is redacted the same way.
assert_exit 0 ds_cli --instance "$inst" doctor --redact
leaks "$DS_STDOUT"
[[ $(head -n 1 <<<"$DS_STDOUT") == "[dotsteward] doctor: "*"<redacted>"* ]] || ds_fail "the instance path is not redacted: $DS_STDOUT"
assert_contains "$DS_STDOUT" "[dotsteward] summary: "

# --redact also works when the configuration is invalid (no context).
bad=$DS_TEST_ROOT/instances/bad
make_minimal_instance "$bad"
printf '\n[gate]\nbogus = 1\n' >>"$bad/workstation.toml"
assert_exit 1 ds_cli --instance "$bad" doctor --json --redact
leaks "$DS_STDOUT"
assert_eq null "$(jq -c .context <<<"$DS_STDOUT")"
