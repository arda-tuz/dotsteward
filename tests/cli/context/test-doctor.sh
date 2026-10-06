# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# dotsteward doctor (SPEC 6.2, 6.5): the health checks built on the context
# (configuration, runtime identity, Nix, launcher cache, mirrors, generation
# manifest, gate memo age), their statuses, the overall status and exit
# code (1 only when a check fails), the JSON document and the human report.
# doctor only reads: the instance and the state root are unchanged.
# shellcheck source=tests/cli/context/helpers.sh
source "$DS_REPO_ROOT/tests/cli/context/helpers.sh"

export DOTSTEWARD_PLATFORM=linux
use_fake_nix
inst=$DS_TEST_ROOT/instances/workstation
make_rich_instance "$inst"
state=$DOTSTEWARD_STATE_ROOT
write_state "$state"
system=$(runtime_system)

doctor_json() {
  ds_cli --instance "$inst" doctor --json "$@"
}

# status ID: the status of check ID in DS_STDOUT.
status() {
  jq -r --arg id "$1" '.checks[] | select(.id == $id) | .status' <<<"$DS_STDOUT"
}

message() {
  jq -r --arg id "$1" '.checks[] | select(.id == $id) | .message' <<<"$DS_STDOUT"
}

snapshot() {
  (cd "$DS_TEST_ROOT" && find instances state home -printf '%p %s %T@\n' | LC_ALL=C sort)
}

# --- A healthy instance, except for the launcher cache and the generation ---------

before=$(snapshot)
assert_exit 0 doctor_json
# doctor only reads.
assert_eq "$before" "$(snapshot)"
assert_eq "" "$DS_STDERR"
assert_eq 1 "$(jq -s length <<<"$DS_STDOUT")"
assert_eq '["schema_version","status","redacted","host","checks","context"]' "$(jq -c keys_unsorted <<<"$DS_STDOUT")"
assert_eq '1 false' "$(jq -r '"\(.schema_version) \(.redacted)"' <<<"$DS_STDOUT")"
assert_eq '["config","identity","nix","launcher-cache","mirrors","generation","gate-memo"]' \
  "$(jq -c '[.checks[].id]' <<<"$DS_STDOUT")"
assert_json - 'all(.checks[]; (keys == ["details","id","message","status"]) and (.details | type == "object"))' <<<"$DS_STDOUT"
# The context is the one `context --json` prints.
assert_eq "$(ds_cli --instance "$inst" context --json | jq -cS .)" "$(jq -cS .context <<<"$DS_STDOUT")"
hostname=$(python3 -c 'import socket; print(socket.gethostname())')
assert_eq "$hostname" "$(jq -r .host.hostname <<<"$DS_STDOUT")"

assert_eq ok "$(status config)"
assert_contains "$(message config)" "$inst/workstation.toml"
# The runtime identity is safe; it differs from the check identity, which
# is not a problem (SPEC 4.4).
assert_eq ok "$(status identity)"
assert_contains "$(message identity)" "check identity"
assert_eq ok "$(status nix)"
assert_contains "$(message nix)" "nix (Nix) 2.31.2"
assert_eq "$DS_TEST_ROOT/bin/nix" "$(jq -r '.checks[] | select(.id == "nix") | .details.path' <<<"$DS_STDOUT")"
assert_eq warn "$(status launcher-cache)"
assert_contains "$(message launcher-cache)" "builds it"
assert_eq ok "$(status mirrors)"
assert_eq warn "$(status generation)"
assert_contains "$(message generation)" "no generation"
assert_eq ok "$(status gate-memo)"
assert_contains "$(message gate-memo)" "2026-01-01T00:00:00Z"
assert_contains "$(message gate-memo)" "days ago"
assert_json - '.checks[] | select(.id == "gate-memo") | .details.age_seconds > 0' <<<"$DS_STDOUT"
assert_eq warn "$(jq -r .status <<<"$DS_STDOUT")"

# --- Launcher cache and generation present -----------------------------------------

key=$(sha256sum "$inst/flake.lock" | cut -d' ' -f1)
mkdir -p "$DS_TEST_ROOT/cli-store/bin" "$state/cli"
printf '#!/bin/sh\n' >"$DS_TEST_ROOT/cli-store/bin/dotsteward"
chmod +x "$DS_TEST_ROOT/cli-store/bin/dotsteward"
ln -s "$DS_TEST_ROOT/cli-store" "$state/cli/$key"
generation=$DS_TEST_ROOT/generation
mkdir -p "$generation/home-path/share/dotsteward"
printf '{}\n' >"$generation/home-path/share/dotsteward/manifest.json"
printf '%s\n' "$generation" >"$state/current/last-built-activation"
assert_exit 0 doctor_json
assert_eq ok "$(status launcher-cache)"
assert_contains "$(message launcher-cache)" "$key"
assert_eq ok "$(status generation)"
assert_contains "$(message generation)" "$generation"
assert_eq ok "$(jq -r .status <<<"$DS_STDOUT")"
# A recorded generation without a dotsteward manifest (built before the
# framework, or collected).
rm "$generation/home-path/share/dotsteward/manifest.json"
assert_exit 0 doctor_json
assert_eq warn "$(status generation)"
printf '{}\n' >"$generation/home-path/share/dotsteward/manifest.json"
# A changed flake.lock is a new key.
printf '\n' >>"$inst/flake.lock"
assert_exit 0 doctor_json
assert_eq warn "$(status launcher-cache)"
cp "$context_fixtures/locks/github.json" "$inst/flake.lock"

# --- Mirrors --------------------------------------------------------------------

mirror=$inst/.dotsteward/manifest.$system.json
cp "$mirror" "$DS_TEST_ROOT/mirror.json"
# The configuration changed after the last sync.
sed -i 's/chore: refresh pins/chore: refresh/' "$inst/workstation.toml"
assert_exit 0 doctor_json
assert_eq warn "$(status mirrors)"
assert_contains "$(message mirrors)" "manifest.$system.json"
assert_contains "$(message mirrors)" "dotsteward sync"
cp "$context_fixtures/instance/workstation.toml" "$inst/workstation.toml"
assert_exit 0 doctor_json
assert_eq ok "$(status mirrors)"
# Another framework version wrote it.
jq '.framework.version = "9.9.9"' "$DS_TEST_ROOT/mirror.json" >"$mirror"
assert_exit 0 doctor_json
assert_eq warn "$(status mirrors)"
assert_contains "$(message mirrors)" "9.9.9"
# Damaged, and missing for a configured system.
printf 'not json\n' >"$mirror"
assert_exit 0 doctor_json
assert_eq warn "$(status mirrors)"
rm "$mirror"
assert_exit 0 doctor_json
assert_eq warn "$(status mirrors)"
assert_contains "$(message mirrors)" "manifest.$system.json is missing"
cp "$DS_TEST_ROOT/mirror.json" "$mirror"
assert_exit 0 doctor_json
assert_eq ok "$(status mirrors)"
# Every configured system is checked: the rich instance also configures
# aarch64-darwin, whose stage-0 file is stage0.darwin.env.
mv "$inst/.dotsteward/stage0.darwin.env" "$DS_TEST_ROOT/stage0.darwin.env"
assert_exit 0 doctor_json
assert_eq warn "$(status mirrors)"
assert_contains "$(message mirrors)" "stage0.darwin.env is missing"
mv "$DS_TEST_ROOT/stage0.darwin.env" "$inst/.dotsteward/stage0.darwin.env"

# --- Gate memo ------------------------------------------------------------------

rm "$state/update/validation.json"
assert_exit 0 doctor_json
assert_eq warn "$(status gate-memo)"
assert_contains "$(message gate-memo)" "no passed gate"
printf 'not json\n' >"$state/update/validation.json"
assert_exit 0 doctor_json
assert_eq warn "$(status gate-memo)"
write_state "$state"

# --- Failures -------------------------------------------------------------------

# Nix missing: the check fails and doctor exits 1 (the Python API is used
# so the host's own Nix installation cannot answer).
PYTHONPATH=$context_framework/cli/python PYTHONDONTWRITEBYTECODE=1 python3 -s -P - <<'EOF' || ds_fail "find_nix found a Nix without candidates"
from dotsteward_cli import doctor
check = doctor.check_nix({"PATH": "/nonexistent"}, fallbacks=())
assert check["status"] == "fail", check
assert "bootstrap" in check["message"], check
EOF

# An unsafe runtime identity: rebuild would refuse it.
assert_exit 1 env USER='Bad User' "$context_framework/cli/dotsteward" --instance "$inst" doctor --json
assert_eq fail "$(status identity)"
assert_eq fail "$(jq -r .status <<<"$DS_STDOUT")"
assert_exit 1 env DOTSTEWARD_PLATFORM=darwin HOME="$DS_TEST_ROOT/with space" \
  "$context_framework/cli/dotsteward" --instance "$inst" doctor --json
assert_eq fail "$(status identity)"

# An invalid configuration: the configuration check fails, the checks that
# need it are skipped, the context is null.
bad=$DS_TEST_ROOT/instances/bad
make_minimal_instance "$bad"
printf '\n[gate]\nbogus = 1\n' >>"$bad/workstation.toml"
assert_exit 1 ds_cli --instance "$bad" doctor --json
assert_eq fail "$(jq -r '.checks[] | select(.id == "config") | .status' <<<"$DS_STDOUT")"
assert_contains "$(jq -r '.checks[] | select(.id == "config") | .message' <<<"$DS_STDOUT")" "unknown key gate.bogus"
assert_eq '["ok","ok","skip","skip","skip","skip"]' \
  "$(jq -c '[.checks[] | select(.id != "config") | .status]' <<<"$DS_STDOUT")"
assert_eq null "$(jq -c .context <<<"$DS_STDOUT")"

# A context source that cannot be read (a file left behind by a root run):
# the configuration check fails with the reason and the report still
# renders, without a traceback; --redact hides the home path in the reason.
# Skipped where permissions do not apply (a root builder reads mode 000).
chmod 000 "$inst/settings-buffer/buffer.toml"
if [[ ! -r $inst/settings-buffer/buffer.toml ]]; then
  assert_exit 1 doctor_json
  assert_not_contains "$DS_STDERR" Traceback
  assert_eq fail "$(jq -r '.checks[0].status' <<<"$DS_STDOUT")"
  assert_contains "$(message config)" "settings-buffer/buffer.toml: cannot read the settings buffer: Permission denied"
  assert_eq '["ok","ok","skip","skip","skip","skip"]' \
    "$(jq -c '[.checks[] | select(.id != "config") | .status]' <<<"$DS_STDOUT")"
  assert_eq null "$(jq -c .context <<<"$DS_STDOUT")"
  assert_exit 1 ds_cli --instance "$inst" doctor
  assert_not_contains "$DS_STDERR" Traceback
  assert_contains "$DS_STDOUT" "[dotsteward] fail config: "
fi
chmod 644 "$inst/settings-buffer/buffer.toml"
home_state=$HOME/.local/state/workstation
write_state "$home_state"
chmod 000 "$home_state/current/profile"
if [[ ! -r $home_state/current/profile ]]; then
  assert_exit 1 env DOTSTEWARD_STATE_ROOT="$home_state" \
    "$context_framework/cli/dotsteward" --instance "$inst" doctor --json --redact
  assert_not_contains "$DS_STDERR" Traceback
  assert_eq 'fail true' "$(jq -r '"\(.checks[0].status) \(.redacted)"' <<<"$DS_STDOUT")"
  assert_contains "$(message config)" "/current/profile: Permission denied"
  assert_not_contains "$DS_STDOUT" "$HOME"
  assert_not_contains "$DS_STDERR" "$HOME"
fi
chmod 644 "$home_state/current/profile"
rm -r "$home_state"

# --- Human report -----------------------------------------------------------------

assert_exit 0 ds_cli --instance "$inst" doctor
assert_eq "" "$DS_STDERR"
assert_contains "$DS_STDOUT" "[dotsteward] doctor: $inst"
assert_contains "$DS_STDOUT" "[dotsteward] ok   config: "
assert_contains "$DS_STDOUT" "[dotsteward] ok   nix: "
assert_contains "$DS_STDOUT" "[dotsteward] summary: 7 ok, 0 warnings, 0 failures"
assert_not_contains "$DS_STDOUT" "\"schema_version\""
assert_exit 1 ds_cli --instance "$bad" doctor
assert_contains "$DS_STDOUT" "[dotsteward] fail config: "
assert_contains "$DS_STDOUT" "[dotsteward] skip mirrors: "
assert_contains "$DS_STDOUT" "[dotsteward] summary: 2 ok, 0 warnings, 1 failure, 4 skipped"
