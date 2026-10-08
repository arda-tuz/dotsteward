# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The context and doctor command lines: discovery through
# the dispatcher, --help, usage errors (exit 1), refusals for a missing or
# invalid instance and an unreadable settings buffer (exit 1, ERROR lines on
# stderr, nothing on stdout), and the human output of context.
# shellcheck source=tests/cli/context/helpers.sh
source "$DS_REPO_ROOT/tests/cli/context/helpers.sh"

export DOTSTEWARD_PLATFORM=linux
inst=$DS_TEST_ROOT/instances/workstation
make_rich_instance "$inst"

# Both commands are listed with their summaries.
assert_exit 0 ds_cli --help
assert_contains "$DS_STDOUT" "context "
assert_contains "$DS_STDOUT" "doctor "

for command in context doctor; do
  assert_exit 0 ds_cli "$command" --help
  assert_contains "$DS_STDOUT" "Usage: dotsteward $command"
  assert_eq "" "$DS_STDERR"
  assert_exit 1 ds_cli --instance "$inst" "$command" --bogus
  assert_eq "" "$DS_STDOUT"
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: "
  assert_contains "$DS_STDERR" "--bogus"
  assert_exit 1 ds_cli --instance "$inst" "$command" extra
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: "
done
assert_exit 0 ds_cli context -h
assert_contains "$DS_STDOUT" "--json"
assert_exit 0 ds_cli doctor --help
assert_contains "$DS_STDOUT" "--redact"

# No instance: walk-up discovery finds nothing.
in_dir() {
  cd "$1" && shift && "$@"
}
mkdir -p "$DS_TEST_ROOT/empty"
assert_exit 1 in_dir "$DS_TEST_ROOT/empty" ds_cli context --json
assert_eq "" "$DS_STDOUT"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: no instance found"

# An invalid workstation.toml: the reader's messages, exit 1.
bad=$DS_TEST_ROOT/instances/bad
make_minimal_instance "$bad"
printf '\n[gate]\nnix_max_jobs = 0\nbogus = 1\n' >>"$bad/workstation.toml"
assert_exit 1 ds_cli --instance "$bad" context --json
assert_eq "" "$DS_STDOUT"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: workstation.toml: gate.nix_max_jobs"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: workstation.toml: unknown key gate.bogus"

# An invalid environment override is a refusal too.
assert_exit 1 env DOTSTEWARD_NIX_CORES=many "$context_framework/cli/dotsteward" --instance "$inst" context --json
assert_contains "$DS_STDERR" "[dotsteward] ERROR: DOTSTEWARD_NIX_CORES"

# A settings buffer that is not valid TOML, or holds entries without ids:
# the facts would be incomplete, so context refuses.
cp "$inst/settings-buffer/buffer.toml" "$DS_TEST_ROOT/buffer.toml"
printf '[[entries]\n' >>"$inst/settings-buffer/buffer.toml"
assert_exit 1 ds_cli --instance "$inst" context --json
assert_eq "" "$DS_STDOUT"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: settings-buffer/buffer.toml"
printf 'schema_version = 1\n[[entries]]\nkind = "key"\n' >"$inst/settings-buffer/buffer.toml"
assert_exit 1 ds_cli --instance "$inst" context --json
assert_contains "$DS_STDERR" "[dotsteward] ERROR: settings-buffer/buffer.toml: entries[0]"
cp "$DS_TEST_ROOT/buffer.toml" "$inst/settings-buffer/buffer.toml"

# A source that exists but cannot be read (a file left behind by a root run)
# is a refusal with an ERROR line, never a traceback: the settings buffer,
# the recorded profile and the framework's source-info. Skipped where
# permissions do not apply (a root builder can read a mode 000 file).
refuses_unreadable() {
  local file=$1 expected=$2
  chmod 000 "$file"
  if [[ -r $file ]]; then
    chmod 644 "$file"
    return 0
  fi
  assert_exit 1 ds_cli --instance "$inst" context --json
  chmod 644 "$file"
  assert_eq "" "$DS_STDOUT"
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: $expected"
  assert_not_contains "$DS_STDERR" Traceback
}
refuses_unreadable "$inst/settings-buffer/buffer.toml" \
  "settings-buffer/buffer.toml: cannot read the settings buffer: Permission denied"
write_state "$DOTSTEWARD_STATE_ROOT"
refuses_unreadable "$DOTSTEWARD_STATE_ROOT/current/profile" \
  "cannot read $DOTSTEWARD_STATE_ROOT/current/profile: Permission denied"
rm -r "${DOTSTEWARD_STATE_ROOT:?}/current" "${DOTSTEWARD_STATE_ROOT:?}/update"
printf 'rev=0123456789abcdef0123456789abcdef01234567\n' >"$context_framework/source-info"
refuses_unreadable "$context_framework/source-info" \
  "cannot read the framework source-info $context_framework/source-info: Permission denied"
rm "$context_framework/source-info"
# Any other unreadable path met while building the context, such as an
# instance directory without permissions, is a refusal too.
chmod 000 "$inst/agent"
if [[ ! -r $inst/agent ]]; then
  assert_exit 1 ds_cli --instance "$inst" context --json
  chmod 755 "$inst/agent"
  assert_eq "" "$DS_STDOUT"
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: cannot read $inst/agent/"
  assert_contains "$DS_STDERR" ": Permission denied"
  assert_not_contains "$DS_STDERR" Traceback
fi
chmod 755 "$inst/agent"
assert_exit 0 ds_cli --instance "$inst" context --json

# A mirror that is not a JSON object is ignored by context (doctor reports
# it); a damaged skills lock is a refusal like the buffer.
printf 'not json\n' >"$inst/.dotsteward/manifest.$(runtime_system).json"
assert_exit 0 ds_cli --instance "$inst" context --json
assert_eq '[]' "$(jq -c '[.components[].commands[]]' <<<"$DS_STDOUT")"
# So is any part of a different shape.
printf '{"schema_version": 1, "components": 1, "settings_targets": [], "checks": {"commands": 5}, "skills": []}\n' \
  >"$inst/.dotsteward/manifest.$(runtime_system).json"
assert_exit 0 ds_cli --instance "$inst" context --json
assert_eq '[[],[]]' "$(jq -c '[[.components[].commands[]], .skills.instance_skill_names - ["example-notes", "example-review"]]' <<<"$DS_STDOUT")"
printf '{"checks": {"commands": "zsh"}, "components": [1, {"name": 2}]}\n' >"$inst/.dotsteward/manifest.$(runtime_system).json"
assert_exit 0 ds_cli --instance "$inst" context --json
assert_eq '[]' "$(jq -c '[.components[].commands[]]' <<<"$DS_STDOUT")"
write_mirror "$inst"
cp "$inst/agent/skills.lock.json" "$DS_TEST_ROOT/skills.lock.json"
printf '{"skills": [{"directory": "x"}]}\n' >"$inst/agent/skills.lock.json"
assert_exit 1 ds_cli --instance "$inst" context --json
assert_contains "$DS_STDERR" "[dotsteward] ERROR: agent/skills.lock.json"
cp "$DS_TEST_ROOT/skills.lock.json" "$inst/agent/skills.lock.json"

# Human output: one "[dotsteward] key: value" line per fact, no JSON.
assert_exit 0 ds_cli --instance "$inst" context
assert_eq "" "$DS_STDERR"
assert_contains "$DS_STDOUT" "[dotsteward] instance.path: $inst"
assert_contains "$DS_STDOUT" "[dotsteward] identity.runtime_matches_check: false"
assert_contains "$DS_STDOUT" "[dotsteward] profiles.names: workstation, fresh"
assert_contains "$DS_STDOUT" "[dotsteward] overlays.dotsteward-contribute: none"
assert_contains "$DS_STDOUT" "[dotsteward] components.codex.method: external"
assert_contains "$DS_STDOUT" "[dotsteward] components.shell.commands: zsh, starship"
assert_contains "$DS_STDOUT" "[dotsteward] settings.entry_ids: codex-model, term-theme, term-font"
assert_contains "$DS_STDOUT" "[dotsteward] protected: agent/AGENTS.md, home/AGENTS.md"
assert_not_contains "$DS_STDOUT" "\"schema_version\""
assert_not_contains "$DS_STDOUT" sentinel-value
while IFS= read -r line; do
  [[ $line == "[dotsteward] "*": "* ]] || ds_fail "unexpected human line: [$line]"
done <<<"$DS_STDOUT"
