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

# The configuration file name is a framework fact and stays, even when the
# remote's repository is named like its stem (the template's "workstation");
# the instance directory named after the repository still goes.
config_message=$(jq -r '.checks[] | select(.id == "config") | .message' <<<"$redacted")
assert_contains "$config_message" "<redacted>/workstation.toml is valid"
assert_not_contains "$redacted" "<redacted>.toml"

# Profile names are data and go; profile modes stay.
assert_eq '{"<redacted>":"adopt","fresh":"fresh"}' "$(jq -c .context.profiles.modes <<<"$redacted")"

# Field names are never redacted, even when the runtime user is also a
# schema key or a part of one (root: state.root and skills.hm_root; user:
# identity.runtime_user; name: instance.name, components[].name). The
# redacted context keeps the schema's shape; its redacted values do not meet
# the value constraints (paths lose their leading /, names repeat).
key_paths='[paths | map(if type == "string" then . else 0 end)]
  | map(select(.[0:3] != ["context","profiles","modes"])) | unique'
for user in root user name; do
  USER=$user LOGNAME=$user ds_cli --instance "$inst" doctor --json >"$DS_TEST_ROOT/plain-$user.json" \
    || [[ -s $DS_TEST_ROOT/plain-$user.json ]] || ds_fail "doctor --json printed nothing for USER=$user"
  USER=$user LOGNAME=$user ds_cli --instance "$inst" doctor --json --redact >"$DS_TEST_ROOT/redacted-$user.json" \
    || [[ -s $DS_TEST_ROOT/redacted-$user.json ]] || ds_fail "doctor --json --redact printed nothing for USER=$user"
  assert_eq "$(jq -c "$key_paths" "$DS_TEST_ROOT/plain-$user.json")" \
    "$(jq -c "$key_paths" "$DS_TEST_ROOT/redacted-$user.json")" "USER=$user changes the field names"
  assert_eq '["string","string"]' \
    "$(jq -c '[.context.state.root, .context.skills.hm_root] | map(type)' "$DS_TEST_ROOT/redacted-$user.json")"
  jq .context "$DS_TEST_ROOT/redacted-$user.json" >"$DS_TEST_ROOT/redacted-context-$user.json"
  validate_shape "$DS_TEST_ROOT/redacted-context-$user.json"
done

# The human report is redacted the same way.
assert_exit 0 ds_cli --instance "$inst" doctor --redact
leaks "$DS_STDOUT"
[[ $(head -n 1 <<<"$DS_STDOUT") == "[dotsteward] doctor: "*"<redacted>"* ]] || ds_fail "the instance path is not redacted: $DS_STDOUT"
assert_contains "$DS_STDOUT" "/workstation.toml is valid"
assert_not_contains "$DS_STDOUT" "<redacted>.toml"
assert_contains "$DS_STDOUT" "[dotsteward] summary: "

# --redact also works when the configuration is invalid (no context).
bad=$DS_TEST_ROOT/instances/bad
make_minimal_instance "$bad"
printf '\n[gate]\nbogus = 1\n' >>"$bad/workstation.toml"
assert_exit 1 ds_cli --instance "$bad" doctor --json --redact
leaks "$DS_STDOUT"
assert_eq null "$(jq -c .context <<<"$DS_STDOUT")"
# Its problems keep the file name they start with.
assert_eq 'workstation.toml: unknown key gate.bogus' \
  "$(jq -r '.checks[] | select(.id == "config") | .details.problems[]' <<<"$DS_STDOUT")"

# An invalid configuration still names its private values in the config
# check's problems; --redact removes them (the raw identity and remote of
# workstation.toml are redaction terms, and the quoted values of the
# problems go), and keeps the schema facts that make the problems useful.
# Schema problems: the username and both homes do not match their patterns.
private=$DS_TEST_ROOT/instances/private
mkdir -p "$private"
cat >"$private/workstation.toml" <<'TOML'
schema_version = 1

[identity]
username = "Alice Smith"
home = "/home/example Carol"
darwin_home = "/Users/example Danvers"

[instance]
remote = "git@github.com:carol-corp/carol-dotfiles.git"

[nix]
state_version = "26.05"

[profiles]
names = ["main"]
TOML
assert_exit 1 ds_cli --instance "$private" doctor --json
plain=$DS_STDOUT
assert_contains "$plain" '\"Alice Smith\" does not match'
assert_contains "$plain" '\"/Users/example Danvers\" does not match'
assert_exit 1 ds_cli --instance "$private" doctor --json --redact
redacted=$DS_STDOUT
for term in Alice Carol Smith Danvers; do
  assert_not_contains "$redacted" "$term" "redacted report of an invalid configuration leaks [$term]"
done
leaks "$redacted"
assert_eq null "$(jq -c .context <<<"$redacted")"
assert_eq "$(jq -c '[.checks[] | [.id, .status]]' <<<"$plain")" "$(jq -c '[.checks[] | [.id, .status]]' <<<"$redacted")"
assert_eq "$(jq '.checks[0].details.problems | length' <<<"$plain")" \
  "$(jq '.checks[0].details.problems | length' <<<"$redacted")"
assert_contains "$(jq -r '.checks[0].details.problems[]' <<<"$redacted")" \
  'identity.username: "<redacted>" does not match "^[A-Za-z_][A-Za-z0-9_.-]*$"'
assert_exit 1 ds_cli --instance "$private" doctor --redact
for term in Alice Carol Smith Danvers; do
  assert_not_contains "$DS_STDOUT" "$term" "redacted human report of an invalid configuration leaks [$term]"
done

# Semantic problems: a username that is not a Linux user name, the remote's
# owner in a profile role and its repository in a profile table name, an
# instance component (a private name, as in the context) in a problem path,
# and a components.order entry without a table (also a private name, quoted
# once and repeated in the hint). The reserved profile name is a schema fact
# and stays.
cat >"$private/workstation.toml" <<'TOML'
schema_version = 1

[identity]
username = "Carol"

[instance]
remote = "git@github.com:carol-corp/carol-dotfiles.git"

[nix]
state_version = "26.05"

[profiles]
names = ["main", "names"]
default = "carol-corp"

[profiles.carol-dotfiles]
mode = "fresh"

[components]
order = ["secret-tool", "hidden-order"]

[components.secret-tool]
enable = true
source = "instance"
profiles = ["ghost"]
TOML
assert_exit 1 ds_cli --instance "$private" doctor --json
plain=$DS_STDOUT
for term in '\"Carol\" is not a valid Linux user name' '\"carol-corp\" is not in profiles.names' \
  'unknown key profiles.carol-dotfiles' components.secret-tool.profiles '\"names\" is reserved' \
  '\"hidden-order\" (neither a catalog component nor a [components.hidden-order] table)'; do
  assert_contains "$plain" "$term"
done
assert_exit 1 ds_cli --instance "$private" doctor --json --redact
redacted=$DS_STDOUT
for term in Carol carol-corp carol-dotfiles secret-tool ghost hidden-order; do
  assert_not_contains "$redacted" "$term" "redacted report of an invalid configuration leaks [$term]"
done
assert_eq "$(jq '.checks[0].details.problems | length' <<<"$plain")" \
  "$(jq '.checks[0].details.problems | length' <<<"$redacted")"
problems=$(jq -r '.checks[0].details.problems[]' <<<"$redacted")
assert_contains "$problems" 'is not a valid Linux user name'
assert_contains "$problems" 'profiles.names[1]: "names" is reserved'
assert_contains "$problems" 'components.order[1]: unknown component name "<redacted>" (neither a catalog component nor a [components.<redacted>] table)'
assert_exit 1 ds_cli --instance "$private" doctor --redact
for term in Carol carol-corp carol-dotfiles secret-tool ghost hidden-order; do
  assert_not_contains "$DS_STDOUT" "$term" "redacted human report of an invalid configuration leaks [$term]"
done
