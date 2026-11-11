# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# A constraint or a hold is one rule, applied everywhere it counts. The version constraint of a deb
# component, from the most specific layer that has one (a platform file before workstation.toml), goes
# to the apt engine in the sudo window with the packages of the component; a hold the owner writes
# for a component in the host file of this machine goes there too, and the host file of another
# machine never binds apt here. The writer leaves every pin of a held component at a version the
# hold does not take, whichever machine holds it, because the shared lock reaches every machine; it
# names it as held, with the machine and the reason. The analysis says what the rules keep.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'

python3 - "$up_inst/workstation.toml" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace(
    'track = ["example-tracked-too"]\n',
    'track = ["example-tracked-too"]\nversion = "2.*"\nreason = "the plugins speak the 2.x protocol"\n',
)
open(path, "w", encoding="utf-8").write(text)
PY
set_toml hosts producer '"example-host"'
mkdir -p "$up_inst/platforms" "$up_inst/hosts"
cat >"$up_inst/platforms/ubuntu-24.04.toml" <<'TOML'
schema_version = 1

[components.example-app]
version = "2.4.*"
reason = "this release ships the 2.4 runtime"
TOML
cat >"$up_inst/hosts/laptop-b.toml" <<'TOML'
schema_version = 1
platform = "ubuntu-24.04"

[holds.example-app]
version = "9"
reason = "the owner keeps example-app below 9 on this laptop"
TOML
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "chore: constraints and holds"
git -C "$up_inst" push -q origin HEAD:main
# The first run publishes the host file of this machine; the owner then writes a hold into it.
assert_exit 3 upgrade --tracked
git -C "$up_inst" pull -q --ff-only origin main
cat >>"$up_inst/hosts/example-host.toml" <<'TOML'

[holds.codex]
version = "3.0.0"
reason = "the owner waits for the plugins of codex 3"
TOML
git -C "$up_inst" commit -q -am "chore(hosts): hold codex on example-host"
git -C "$up_inst" push -q origin HEAD:main

move agent_tools.codex.linux 3.1.0 download
move agent_tools.codex-helper.linux 2.9.0 download
move nix_packages.example-app 9.5 nix
move example.other 3.0.0 pypi
printf '%s\n' '{"items": [
  {"id": "agent_tools.codex.linux", "latest": "3.1.0", "status": "review"},
  {"id": "agent_tools.codex-helper.linux", "latest": "2.9.0", "status": "update"},
  {"id": "nix_packages.example-app", "latest": "9.5", "status": "update"},
  {"id": "example.other", "latest": "3.0.0", "status": "update"}]}' >"$UP_CONTROL/latest-rows"
apt_answer analysis '{"available": true, "count": 0, "packages": [], "kernels": 2, "boot_free_mib": 900, "boot_low": false,
  "kept": [{"name": "example-tracked", "current": "2.4.1-1", "candidate": "2.4.2-1", "free": "3.0-1", "why": "constraint",
            "component": "example-app", "version": "2.4.*", "reason": "this release ships the 2.4 runtime"}]}'
clear_log
assert_exit 0 on_terminal -- --tracked

# --- the apt engine: the rule of the platform layer, the packages of the component -------------------
policy=$(steps '^apt policy ' | sed -n 1p)
[[ -n $policy ]] || ds_fail "no policy step: $(<"$UP_LOG")"
printf '%s\n' "${policy#apt policy }" >"$DS_TEST_ROOT/policy.json"
assert_json "$DS_TEST_ROOT/policy.json" '.constraints == {"example-app": "2.4.*"}'
assert_json "$DS_TEST_ROOT/policy.json" '.kept == [{"component": "example-app", "kind": "constraint", "version": "2.4.*",
  "reason": "this release ships the 2.4 runtime", "packages": ["example-tracked", "example-tracked-lib", "example-tracked-too"]}]'
assert_contains "$(steps '^apt commit ')" '"kept":[{"component":"example-app"'

# --- the writer: the pins of a held component wait at a version the hold does not take ------------
apply=$(steps '^pins .*apply')
assert_contains "$apply" "--skip agent_tools.codex.linux"
assert_not_contains "$apply" "--skip agent_tools.codex-helper.linux"
assert_contains "$apply" "--skip nix_packages.example-app"
assert_not_contains "$apply" "--skip example.other"
lock=$(git -C "$up_bare" show main:versions.lock.json)
assert_eq "null 2.9.0 null 3.0.0" "$(jq -r '[."agent_tools.codex.linux", ."agent_tools.codex-helper.linux", ."nix_packages.example-app", ."example.other"] | map(. // "null") | join(" ")' <<<"$lock")"
review_json '[.items[] | select(.code == "held" and .id == "codex" and .machine == "example-host" and .version == "3.0.0")] | length == 1'
review_json '[.items[] | select(.code == "held" and .id == "example-app" and .machine == "laptop-b" and (.reason | contains("below 9")))] | length == 1'
assert_contains "$DS_STDOUT" "the owner waits for the plugins of codex 3"
# A hold the owner wrote is no hold of upgrade: --retry-held leaves it.
clear_log
assert_exit 0 on_terminal -- --tracked --retry-held
assert_contains "$(git -C "$up_bare" show main:hosts/example-host.toml)" "[holds.codex]"
assert_contains "$(steps '^pins .*apply')" "--skip agent_tools.codex.linux"

# --- the analysis says what the rules keep, and offers none of it ---------------------------------
assert_contains "$DS_STDOUT" "apt kept 1 back on purpose (example-tracked 2.4.2-1 not 3.0-1: version 2.4.* of example-app)"
assert_not_contains "$DS_STDOUT" "Update these too"
assert_json "$DOTSTEWARD_STATE_ROOT/upgrade/analysis.json" '.channels.apt.kept[0].why == "constraint"'
