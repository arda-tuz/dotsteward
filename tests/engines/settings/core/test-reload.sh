# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and settings_* variables come from the harness and helpers.sh
# Reload hooks: a name resolved in the registry of the targets file (the
# legacy herdr-server form), inline tables, once per hook per flush and only
# after a write, require_command, {home} expansion, env and unset_env,
# timeouts, failures per on_failure, success per on_success, and unknown
# names.
# shellcheck source=tests/engines/settings/core/helpers.sh
source "$DS_REPO_ROOT/tests/engines/settings/core/helpers.sh"

ds_use_stubs herdr example-app
export HERDR_SOCKET_PATH=$DS_TEST_ROOT/herdr.sock

targets=$DS_TEST_ROOT/targets.json
cat >"$targets" <<'EOF'
{
  "schema_version": 1,
  "targets": {},
  "reload_hooks": {
    "herdr-server": {
      "component": "herdr",
      "command": ["herdr", "server", "reload-config"],
      "timeout": 15,
      "env": {"HOME": "{home}", "XDG_CONFIG_HOME": "{home}/.config"},
      "unset_env": ["HERDR_SOCKET_PATH"],
      "require_command": "herdr",
      "on_success": "log",
      "on_failure": "silent"
    }
  }
}
EOF

# The legacy string form resolves in the registry: herdr runs once with
# HOME and XDG_CONFIG_HOME of --home and without HERDR_SOCKET_PATH, and only
# when the target was written. Two targets sharing the hook reload once.
settings_buffer R <<'EOF'
schema_version = 1

[targets.one]
path = "~/.config/herdr/config.toml"
format = "toml"
create_if_missing = true
reload = "herdr-server"

[targets.two]
path = "~/.config/herdr/extra.toml"
format = "toml"
create_if_missing = true
reload = "herdr-server"

[[entries]]
id = "one-key"
target = "one"
key = ["onboarding"]
value = false

[[entries]]
id = "two-key"
target = "two"
key = ["theme"]
value = "dark"
EOF
home=$settings_work/R/home
assert_exit 0 lmf R --targets-file "$targets" apply
assert_calls "herdr server reload-config" \
  "herdr:env HOME=$(printf '%q' "$home") XDG_CONFIG_HOME=$(printf '%q' "$home/.config") -HERDR_SOCKET_PATH"
assert_contains "$DS_STDOUT" "herdr-server"
# Nothing to write: no reload.
assert_exit 0 lmf R --targets-file "$targets" apply
assert_call_count 1 herdr
# A remote change to one target reloads once more.
python3 - "$settings_work/R/repo/local-maintained-files/buffer.toml" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read().replace('value = "dark"', 'value = "light"')
open(path, "w", encoding="utf-8").write(text)
PY
assert_exit 0 lmf R --targets-file "$targets" reconcile
assert_eq first-contact "$(lmf R --targets-file "$targets" status --json | jq -r '.entries[] | select(.id == "two-key") | .state')"
assert_exit 0 lmf R --targets-file "$targets" apply
assert_call_count 2 herdr
# A failure is silent with on_failure = silent; the apply still succeeds.
ds_stub_set herdr reload-exit 4
set_line "$settings_work/R/repo/local-maintained-files/buffer.toml" 'value = "light"' 'value = "dim"'
assert_exit 0 lmf R --targets-file "$targets" apply
assert_call_count 3 herdr
assert_not_contains "$DS_STDERR" "reload"
assert_not_contains "$DS_STDOUT" "herdr-server"
ds_stub_set herdr reload-exit 0

# Without the registry the name is unknown: the target's rows are errors and
# apply refuses before any write.
before=$(sha "$home/.config/herdr/config.toml")
set_line "$settings_work/R/repo/local-maintained-files/buffer.toml" 'value = false' 'value = true'
assert_exit 2 lmf R apply
assert_contains "$DS_STDERR" "unknown reload hook"
assert_eq "$before" "$(sha "$home/.config/herdr/config.toml")"
assert_eq error "$(state_of R one-key)"
assert_call_count 3 herdr

# Inline tables: {home} expands in the argv and in env values, env is set,
# unset_env removed, on_success = silent prints nothing about the hook.
settings_buffer I <<'EOF'
schema_version = 1

[targets.app]
path = "~/.config/example-app/settings.json"
format = "json"
create_if_missing = true

[targets.app.reload]
command = ["example-app", "reload", "--home", "{home}"]
env = { EXAMPLE_CONFIG = "{home}/.config/example-app" }
unset_env = ["HERDR_SOCKET_PATH"]
require_command = "example-app"

[[entries]]
id = "app-key"
target = "app"
key = ["level"]
value = 1
EOF
ds_stub_set example-app env "EXAMPLE_CONFIG HERDR_SOCKET_PATH"
inline_home=$settings_work/I/home
assert_exit 0 lmf I apply
assert_eq "example-app reload --home $(printf '%q' "$inline_home")" "$(ds_calls_of example-app)"
assert_eq "example-app:env EXAMPLE_CONFIG=$(printf '%q' "$inline_home/.config/example-app") -HERDR_SOCKET_PATH" \
  "$(ds_env_of example-app)"
assert_not_contains "$DS_STDOUT" "example-app reload"

# require_command missing: the hook is skipped without a message.
settings_buffer S <<'EOF'
schema_version = 1

[targets.app]
path = "~/.config/skip/settings.json"
format = "json"
create_if_missing = true
reload = { command = ["herdr", "server", "reload-config"], require_command = "dotsteward-missing-command" }

[[entries]]
id = "skip-key"
target = "app"
key = ["level"]
value = 1
EOF
herdr_calls=$(ds_call_count herdr)
assert_exit 0 lmf S apply
assert_eq "$herdr_calls" "$(ds_call_count herdr)"
[[ -f $settings_work/S/home/.config/skip/settings.json ]] || ds_fail "the target was not written"

# A hook that outlives its timeout is abandoned with a warning; a failing
# hook with on_failure = warn warns with its exit status; neither fails the
# command.
settings_buffer T <<'EOF'
schema_version = 1

[targets.slow]
path = "~/.config/slow/config.toml"
format = "toml"
create_if_missing = true
reload = { command = ["herdr", "server", "reload-config"], timeout = 1 }

[[entries]]
id = "slow-key"
target = "slow"
key = ["level"]
value = 1
EOF
ds_stub_set herdr reload-sleep 60
started=$SECONDS
assert_exit 0 lmf T apply
((SECONDS - started < 20)) || ds_fail "the timed-out hook was waited for"
assert_contains "$DS_STDERR" "WARNING"
assert_contains "$DS_STDERR" "timed out"
ds_stub_set herdr reload-sleep 0
ds_stub_set herdr reload-exit 7
set_line "$settings_work/T/repo/local-maintained-files/buffer.toml" 'value = 1' 'value = 2'
assert_exit 0 lmf T apply
assert_contains "$DS_STDERR" "WARNING"
assert_contains "$DS_STDERR" "exit 7"

# Invalid inline tables are buffer errors (exit 2) for every command.
settings_buffer V <<'EOF'
schema_version = 1

[targets.bad]
path = "~/.config/bad/config.toml"
format = "toml"
create_if_missing = true
reload = { command = [], on_failure = "explode" }
EOF
assert_exit 2 lmf V status
assert_contains "$DS_STDERR" "targets.bad.reload"
