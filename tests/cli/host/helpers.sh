# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# Helpers for the tests of machine names and scopes (tests/cli/host). Not a test
# file.
#
# Sourcing this file sources tests/cli/e2e/helpers.sh: a synthetic framework
# copy agents_fw and an instance agents_inst, a git repository whose origin
# (git@github.com:example-org/workstation.git) is the bare repository e2e_bare,
# which passes every E2E check as it is and has neither a hosts directory nor a
# machine.json. It adds:
#
#   run_host ARG...        dotsteward --instance <instance> host ARG... (standard
#                          input empty)
#   run_skills ARG...      dotsteward --instance <instance> skills ARG...
#   write_host NAME [TOML] commits nothing: hosts/NAME.toml with schema_version 1,
#                          then the text TOML
#   name_machine NAME [JQ_FILTER]
#                          machine.json as `host init` writes it for NAME, then
#                          JQ_FILTER
#   effective JQ_FILTER    jq -c JQ_FILTER over `skills effective --json`
#   machine_file           the path of machine.json
#   set_machines NAME JSON the machines key of the lock entry NAME

# shellcheck source=tests/cli/e2e/helpers.sh
source "$DS_REPO_ROOT/tests/cli/e2e/helpers.sh"

# `host publish` scans what it publishes with the policy of the framework.
cp -R "$DS_REPO_ROOT/privacy" "$agents_fw/"

run_host() {
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" host "$@" </dev/null
}

run_skills() {
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" skills "$@" </dev/null
}

write_host() {
  mkdir -p "$agents_inst/hosts"
  printf 'schema_version = 1\n%s\n' "${2:-}" >"$agents_inst/hosts/$1.toml"
}

machine_file() {
  printf '%s\n' "$DOTSTEWARD_STATE_ROOT/machine.json"
}

name_machine() {
  jq -n --arg name "$1" '{
    schema_version: 1, name: $name, machine_key: "00112233445566778899aabbccddeeff",
    named_at: "2026-01-01T00:00:00Z",
    host: { system: "x86_64-linux", profile: "workstation", platform: "ubuntu-24.04", tags: [] }
  }' | jq "${2:-.}" >"$(machine_file)"
}

effective() {
  assert_exit 0 run_skills effective --json
  jq -c "$1" <<<"$DS_STDOUT"
}

set_machines() {
  lock_edit '(.skills[] | select(.name == $name)).machines = $machines' --arg name "$1" --argjson machines "$2"
}

# on_tty ANSWERS ARG...: dotsteward --instance <instance> ARG... on a pseudo terminal
# (standard input and both output streams), like a person in a terminal: each line of
# ANSWERS is typed when the output stops at a prompt, a line that ends in ": " or
# "] ". The output goes to standard output with carriage returns removed, and the
# status is the status of the command.
on_tty() {
  local answers=$1
  shift
  python3 -I - "$answers" "$agents_fw/cli/dotsteward" --instance "$agents_inst" "$@" <<'PY'
import os
import pty
import select
import sys
import time

answers = [line for line in sys.argv[1].split("\n") if sys.argv[1]]
pid, fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[2], sys.argv[2:])
output = b""
typed = 0
deadline = time.monotonic() + 120
while time.monotonic() < deadline:
    ready, _, _ = select.select([fd], [], [], 0.2)
    if ready:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        output += chunk
        continue
    # The output stopped: a prompt waits for the next answer.
    if typed < len(answers) and output.rstrip(b" ").endswith((b":", b"]")) and output.endswith(b" "):
        os.write(fd, answers[typed].encode() + b"\n")
        typed += 1
_, status = os.waitpid(pid, 0)
sys.stdout.write(output.decode("utf-8", "replace").replace("\r", ""))
sys.exit(os.waitstatus_to_exitcode(status))
PY
}
