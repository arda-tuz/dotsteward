# shellcheck shell=bash
# `dotsteward pins check`: group isolation (a missing or malformed lock
# field aborts only its rule, as one failure line, and every other rule
# still runs), the manifest mirrors of every configured system (union of
# their rules, duplicates once), and exit 2 for broken inputs: missing or
# invalid mirrors, invalid rule and latest declarations, unreadable lock
# files and an invalid configuration.
# shellcheck source=tests/engines/pins/check/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/check/helpers.sh"

pins_instance
E='[pins] ERROR: '
mirror=$inst/.dotsteward/manifest.x86_64-linux.json

assert_exit 0 pins check
count=$(check_count)

# --- group isolation ------------------------------------------------------------

pins_fresh
json_edit "$versions" 'del data["assets"]["example"]["sha256"]; data["nix_packages"]["example-lint"]["resolved"] = "0.9.1"'
check_fails 2 \
  "${E}example-asset/asset-digest: missing or invalid lock field (KeyError('assets.example.sha256'))" \
  "${E}nix_packages.example-lint.resolved: expected '0.9.0', found '0.9.1'"

# A malformed value (a string where an object belongs) is caught the same
# way; the other rules still report.
pins_fresh
json_edit "$versions" 'data["flake_inputs"]["nixpkgs"] = "broken"; data["nix_packages"]["example-lint"]["resolved"] = "0.9.1"'
assert_exit 1 pins check
assert_contains "$DS_STDERR" "${E}core/flake-inputs: missing or invalid lock field ("
assert_contains "$DS_STDERR" "${E}nix_packages.example-lint.resolved: expected '0.9.0', found '0.9.1'"
assert_not_contains "$DS_STDERR" "Traceback"

pins_fresh
json_edit "$versions" 'del data["nix_packages"]["example-term"]'
assert_exit 1 pins check
assert_contains "$DS_STDERR" "${E}example-term/derive: missing or invalid lock field (KeyError('nix_packages.example-term.expected'))"
assert_contains "$DS_STDERR" "${E}example-term/skills-lock-mirror: missing or invalid lock field (KeyError('nix_packages.example-term.resolved'))"
assert_contains "$DS_STDERR" "${E}example_policy.minimum_versions.example-term: expected at least '1.0', found None"
assert_not_contains "$DS_STDERR" "Traceback"

# A missing skills lock fails the rules that read it; the other rules run.
pins_fresh
rm "$skills"
assert_exit 1 pins check
assert_contains "$DS_STDERR" "${E}example-term/skills-lock-mirror: missing or invalid lock field (KeyError('skills:nix_tools'))"
assert_not_contains "$DS_STDERR" "Traceback"

# --- mirrors of every configured system -----------------------------------------

pins_fresh
sed -i 's/^state_version = .*/&\nsystems = ["x86_64-linux", "aarch64-darwin"]/' "$inst/workstation.toml"
assert_exit 2 pins check
assert_eq "${E}missing manifest mirror .dotsteward/manifest.aarch64-darwin.json; run 'dotsteward sync'" "$DS_STDERR"
assert_eq "" "$DS_STDOUT"

# The darwin mirror repeats every rule (counted once) and adds one.
python3 - "$mirror" "$inst/.dotsteward/manifest.aarch64-darwin.json" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
manifest["system"] = "aarch64-darwin"
manifest["platform"] = "darwin"
manifest["pins"]["rules"].append(
    {"component": "example-darwin", "kind": "derive", "to": "nix_packages.example-shell.notes", "template": "follows nixpkgs"}
)
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
assert_exit 0 pins check
assert_eq "[pins] All pin consistency checks passed ($((count + 1)) checks)" "$DS_STDOUT"
json_edit "$versions" 'data["nix_packages"]["example-shell"]["notes"] = "other"'
check_fails 1 "${E}nix_packages.example-shell.notes: expected 'follows nixpkgs', found 'other'"

# --- exit 2: broken inputs ------------------------------------------------------

pins_fresh
rm "$mirror"
assert_exit 2 pins check
assert_eq "${E}missing manifest mirror .dotsteward/manifest.x86_64-linux.json; run 'dotsteward sync'" "$DS_STDERR"

pins_fresh
printf '{ "schema_version": 1, ' >"$mirror"
assert_exit 2 pins check
assert_contains "$DS_STDERR" "${E}.dotsteward/manifest.x86_64-linux.json: invalid JSON"
assert_not_contains "$DS_STDERR" "Traceback"

pins_fresh
json_edit "$mirror" 'data["schema_version"] = 2'
assert_exit 2 pins check
assert_contains "$DS_STDERR" "${E}.dotsteward/manifest.x86_64-linux.json: unsupported schema_version 2"

pins_fresh
json_edit "$mirror" 'data["pins"]["rules"][0]["kind"] = "example-kind"'
assert_exit 2 pins check
assert_eq "${E}.dotsteward/manifest.x86_64-linux.json: rule 1 (component example-term): unknown kind 'example-kind'" "$DS_STDERR"

pins_fresh
json_edit "$mirror" 'r = data["pins"]["rules"][0]; r["tto"] = r.pop("to")'
assert_exit 2 pins check
assert_eq "${E}example-term/derive: invalid declaration: missing field 'to'; unknown field 'tto'" "$DS_STDERR"

pins_fresh
json_edit "$mirror" 'data["pins"]["rules"][0]["template"] = "{flake_inputs.example-term.version}"'
assert_exit 2 pins check
assert_eq "${E}example-term/derive: invalid declaration: exactly one of 'from' and 'template' is required" "$DS_STDERR"

pins_fresh
json_edit "$mirror" 'data["pins"]["rules"][2]["template"] = "v{agent_tools.example-app.version"'
assert_exit 2 pins check
assert_contains "$DS_STDERR" "${E}example-app/derive: invalid declaration: field 'template': unbalanced '{'"

pins_fresh
json_edit "$mirror" 'data["pins"]["rules"][2]["formats"] = {"agent_tools.example-app.version": "example-format"}'
assert_exit 2 pins check
assert_contains "$DS_STDERR" "${E}example-app/derive: invalid declaration: field 'formats': unknown format 'example-format'"

pins_fresh
json_edit "$mirror" 'data["pins"]["rules"][1]["pairs"][0]["to"] = "nix_tools.{key}"'
assert_exit 2 pins check
assert_contains "$DS_STDERR" "${E}example-term/skills-lock-mirror: invalid declaration: field 'pairs': pair 1: 'to' must be a skills: path"

# The pins latest declarations are validated too (no query runs): a field
# no adapter knows fails the check, not the next update.
pins_fresh
json_edit "$mirror" 'data["pins"]["latest"] = [{"id": "agent_tools.example-app", "adapter": "local-apt", "component": "example-app", "package": "example-app", "current_at": "agent_tools.example-app.version"}]'
assert_exit 2 pins check
assert_eq "${E}example-app/agent_tools.example-app: invalid declaration: unknown field 'current_at'" "$DS_STDERR"
json_edit "$mirror" 'data["pins"]["latest"] = [{"id": "agent_tools.example-app", "adapter": "local-apt", "component": "example-app", "package": "example-app"}]'
assert_exit 0 pins check

pins_fresh
printf '{\n' >"$versions"
assert_exit 2 pins check
assert_contains "$DS_STDERR" "${E}cannot read versions.lock.json: "
assert_not_contains "$DS_STDERR" "Traceback"

pins_fresh
rm "$versions"
assert_exit 2 pins check
assert_contains "$DS_STDERR" "${E}cannot read versions.lock.json: "

# [pins] versions_lock and [skills] lock move the lock files.
pins_fresh
mkdir -p "$inst/locks"
git -C "$inst" mv versions.lock.json locks/versions.json
git -C "$inst" mv agent/skills.lock.json locks/skills.json
printf '\n[pins]\nversions_lock = "locks/versions.json"\n\n[skills]\nlock = "locks/skills.json"\n' >>"$inst/workstation.toml"
assert_exit 0 pins check
json_edit "$inst/locks/skills.json" 'data["nix_tools"]["example-term"] = "1.1.0"'
check_fails 1 "${E}skills:nix_tools.example-term: expected '1.2.0', found '1.1.0'"

# [pins] excluded_flake_inputs replaces the default ["dotsteward"].
pins_fresh
printf '\n[pins]\nexcluded_flake_inputs = []\n' >>"$inst/workstation.toml"
check_fails 1 "${E}flake.lock root inputs: expected ['example-term', 'nixpkgs'], found ['dotsteward', 'example-term', 'nixpkgs']"

pins_fresh
printf '\n[example_unknown]\nkey = 1\n' >>"$inst/workstation.toml"
assert_exit 2 pins check
assert_contains "$DS_STDERR" "example_unknown"
assert_not_contains "$DS_STDERR" "Traceback"
