# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# shellcheck disable=SC2016 # the scripts of tool_stub run later and are single-quoted on purpose
# E30: the menu on a terminal, tracked mode with its read only analysis and its one offer, everything
# with no second question. Updating what is not tracked does not track it: the intent, the shared
# lock and the key of E2E stay. --plan writes both modes and changes nothing. The profile comes from
# the machine, never from the default of the instance.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
tool_stub snap 'if [[ ${2:-} == --list ]]; then printf "Name Version Rev Size Publisher Notes\nexample-snap 2.0 7 1MB me -\n"; fi'
tool_stub flatpak 'case "$1" in remote-ls) printf "org.example.App\t2.0\tflathub\n";; esac'
tool_stub example-lang 'case "$1" in check) printf "stable 1.89.0 -> 1.90.0\n";; esac'
tool_stub example-pkgs 'case "$1" in outdated) printf "example-tool 1.0 2.0\n";; esac'
# Two installs of one tool, one with a package that provides a tracked command.
tool_stub example-globals 'case "$1" in
  outdated) printf "v22/example-global 1 2\nv24/example-global 1 2\nv24/codex-copy 1 2\n";;
  provides) case "$2" in */codex-copy) printf "codex\n";; *) printf "example-global\n";; esac;;
esac'
declare_tool example-globals 'example-globals outdated' 'example-globals update "$@"' 'example-globals provides "$1"'
declare_tool example-lang 'example-lang check' 'example-lang update stable'
declare_tool example-pkgs 'example-pkgs outdated' 'example-pkgs upgrade --all'

apt_answer analysis '{"available": true, "count": 3, "phased": 1,
  "packages": [{"name": "libexample", "current": "1", "candidate": "2", "origin": "noble-updates", "phased": true},
               {"name": "example-b", "current": "1", "candidate": "2", "origin": "noble-updates", "phased": false},
               {"name": "example-c", "current": "1", "candidate": "2", "origin": "noble-updates", "phased": false}],
  "kernels": 2, "boot_free_mib": 120, "boot_low": true}'

lock_before=$(sha256sum "$up_inst/versions.lock.json")
toml_before=$(sha256sum "$up_inst/workstation.toml")

# --- the menu, tracked, the offer declined -------------------------------------------------------
assert_exit 0 on_terminal 'Update what=1' 'Update these too=n' --
assert_contains "$DS_STDOUT" "Tracked only"
assert_contains "$DS_STDOUT" "Everything"
assert_contains "$(steps '^apt commit')" '"mode":"tracked"'
assert_no_step '^(sudo -n )?snap refresh$'
assert_no_step '^example-lang update'
assert_no_step '^example-pkgs upgrade'
assert_no_step '^example-globals update'
# What the channels read is read only, and the analysis is said channel by channel.
assert_order '^snap refresh --list' '^flatpak remote-ls' '^example-globals outdated' '^example-lang check' '^example-pkgs outdated'
assert_contains "$DS_STDOUT" "apt 3"
assert_contains "$DS_STDOUT" "/boot"
analysis=$DOTSTEWARD_STATE_ROOT/upgrade/analysis.json
assert_file_mode "$analysis" 600
assert_json "$analysis" '.channels.apt.count == 3 and .channels.apt.boot_free_mib == 120'
assert_json "$analysis" '.channels["example-globals"].items | map(.name) == ["v22/example-global", "v24/example-global"]'
assert_json "$analysis" '.channels["example-globals"].skipped == [{"name": "v24/codex-copy", "reason": "tracked-command"}]'
assert_json "$analysis" '.channels.snap.items[0].name == "example-snap"'
assert_json "$analysis" '.channels.flatpak.items[0].application == "org.example.App"'
assert_json "$analysis" '.channels["example-lang"].count == 1 and .channels["example-pkgs"].count == 1'
review_json '[.items[] | select(.code == "boot-space-low")] | length == 1'
# review.json has numbers and a path, no package names: the analysis stays local.
review_json '[.items[] | select(.code == "analysis") | .counts.apt] == [3]'
assert_not_contains "$(cat "$DOTSTEWARD_STATE_ROOT/review.json")" "libexample"
assert_not_contains "$(git -C "$up_inst" log -p --format=%s | cat)" "libexample"

# --- the offer accepted: the rest runs, Nix and self do not again ---------------------------------
clear_log
apt_answer commit-all '{"status": "committed", "committed": true,
  "changes": {"install": [], "upgrade": [{"name": "example-b", "from": "1", "to": "2"}], "remove": [], "downgrade": []},
  "items": [], "gated": {"decision": "no-move"}, "applicable": true}'
assert_exit 0 on_terminal 'Update what=1' 'Update these too=y' --
assert_eq 2 "$(steps '^apt commit' | wc -l | tr -d ' ')" "the first pass and the offer"
assert_contains "$(steps '^apt commit' | tail -n 1)" '"mode":"all"'
assert_eq 2 "$(steps '^sudo -v' | wc -l | tr -d ' ')" "the offer opens sudo again"
assert_order '^sudo -v' '^sudo -k' '^pins .*apply' '^sudo -v'
assert_order '^sudo -n snap refresh$' '^sudo -n flatpak update --system' \
  '^example-globals update v22/example-global v24/example-global$' '^example-lang update stable' '^example-pkgs upgrade --all'
assert_no_step 'example-globals update .*codex-copy'
assert_eq 1 "$(steps '^claude update' | wc -l | tr -d ' ')" "self runs once"
assert_eq 1 "$(steps '^pins .*apply' | wc -l | tr -d ' ')" "the writer runs once"
assert_eq 1 "$(steps '^e2e ' | wc -l | tr -d ' ')" "E2E of the pass that moved apt"
assert_order '^example-pkgs upgrade --all' '^e2e '

# Nothing untracked entered the repository.
assert_eq "$lock_before" "$(sha256sum "$up_inst/versions.lock.json")"
assert_eq "$toml_before" "$(sha256sum "$up_inst/workstation.toml")"

# --- everything: no second question, no analysis ---------------------------------------------------
clear_log
apt_answer commit-all "$NOTHING_CHANGED"
rm -f -- "$analysis"
assert_exit 0 on_terminal 'Update what=2' --
assert_not_contains "$DS_STDOUT" "Update these too"
assert_contains "$(steps '^apt commit')" '"mode":"all"'
assert_order '^apt commit' '^sudo -n snap refresh$' '^sudo -n flatpak update --system' '^sudo -k' '^claude update' '^example-globals update v22/example-global' '^example-lang update stable'
[[ ! -e $analysis ]] || ds_fail "--all has no analysis"
last_report '.data.mode == "all"'

clear_log
assert_exit 0 on_terminal -- --all
assert_not_contains "$DS_STDOUT" "Update what"

# --- plan: both modes, nothing changes --------------------------------------------------------------
clear_log
apt_answer plan '{"status": "nothing", "changes": {"install": [], "upgrade": [{"name": "example-tracked", "from": "1", "to": "2"}], "remove": [], "downgrade": []}, "items": [], "gated": {"decision": "no-move"}, "applicable": true}'
before_state=$(find "$DOTSTEWARD_STATE_ROOT" -type f -not -path '*/skills/*' -exec sha256sum {} + | sort)
head_before=$(git -C "$up_inst" rev-parse HEAD)
assert_exit 0 upgrade --plan --json
assert_stdout_json '.tracked.apt.changes.upgrade[0].name == "example-tracked"'
assert_stdout_json '(.all.apt | type) == "object"'
assert_stdout_json '.channels["example-lang"].count == 1'
assert_stdout_json '.self == ["claude-code"]'
assert_stdout_json '.producer == "this-machine"'
assert_eq "$before_state" "$(find "$DOTSTEWARD_STATE_ROOT" -type f -not -path '*/skills/*' -exec sha256sum {} + | sort)"
assert_eq "$head_before" "$(git -C "$up_inst" rev-parse HEAD)"
assert_no_step '^(sudo|apt commit|apt recover|apt policy|rebuild|e2e|claude update)'
assert_no_step '^pins apply$'

# A plan is read by a person too.
assert_exit 0 upgrade --plan
assert_contains "$DS_STDOUT" "Tracked only"
assert_contains "$DS_STDOUT" "Everything"

# --- --json leaves standard output to the document ---------------------------------------------------
clear_log
assert_exit 3 upgrade --tracked --json
assert_stdout_json '.command == "upgrade" and .exit_code == 3 and (.review | endswith("review.json"))'

# --- a deb component with another updater is not the business of the apt plan -------------------------
python3 - "$up_inst/workstation.toml" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace('[components.example-app]\nenable = true\nmethod = "deb"\n', '[components.example-app]\nenable = true\nmethod = "deb"\nupdater = "self"\n')
open(path, "w", encoding="utf-8").write(text)
PY
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "feat: example-app updates itself"
git -C "$up_inst" push -q origin HEAD:main
clear_log
assert_exit 0 on_terminal 'Update these too=n' -- --tracked
assert_contains "$(steps '^apt commit')" '"tracked":[]'

# --- the profile: a machine without one is told, the default of the instance never runs ---------------
clear_log
rm -f -- "$DOTSTEWARD_STATE_ROOT/machine.json" "$DOTSTEWARD_STATE_ROOT/current/profile" \
  "$DOTSTEWARD_STATE_ROOT/current/activation.json"
assert_exit 3 upgrade --tracked
review_json '[.items[] | select(.code == "machine-name-required")] | length == 1'
assert_no_step '^rebuild '
assert_no_step '^e2e '
