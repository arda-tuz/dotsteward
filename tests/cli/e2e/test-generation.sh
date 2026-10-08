# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# --generation PATH (pre-switch runs): the manifest comes
# from the built generation instead of the mirror (or the active
# generation), its home-path/bin is first on PATH for every check, and the
# agents check verifies against it too.
# shellcheck source=tests/cli/e2e/helpers.sh
source "$DS_REPO_ROOT/tests/cli/e2e/helpers.sh"

ds_use_stubs example-app
none='{"command": null, "versionArgv": null, "minimum": null}'
add_component example-app external "$none"
# The mirror expects a command only the built generation provides and a
# hook only the built generation drops.
manifest_edit '.checks.commands = [{component: "example-app", command: "example-term"}]'
printf 'exit 9\n' | add_e2e_hook example-app retired main
publish_instance

make_generation
ln -s "$(command -v example-app)" "$agents_gen/home-path/bin/example-term"
jq '.checks.e2e = []' "$agents_manifest" >"$agents_gen/home-path/share/dotsteward/manifest.json"

assert_exit 1 run_e2e --json --keep-going
assert_eq '[["core:commands","missing-command","example-term"],["example-app:retired","hook-failed","example-app/retired"]]' \
  "$(findings)"
assert_exit 0 run_e2e --generation "$agents_gen" --list
assert_not_contains "$DS_STDOUT" "example-app:retired"
assert_exit 0 run_e2e --generation "$agents_gen"
assert_contains "$DS_STDOUT" "[dotsteward] e2e checks passed (profile workstation)"

# The active generation is used when no --generation is given, but its
# home-path/bin is not put on PATH (activation already did).
activate_generation
assert_exit 1 run_e2e --json --keep-going
assert_eq '[["core:commands","missing-command","example-term"]]' "$(findings)"

# The agents check of the run verifies against the given generation: with
# no active generation, framework skills are verifiable only through it.
rm "$HOME/.local/state/home-manager/gcroots/current-home"
framework_skill dotsteward-maintain
publish_instance
make_generation
ln -s "$(command -v example-app)" "$agents_gen/home-path/bin/example-term"
jq '.checks.e2e = []' "$agents_manifest" >"$agents_gen/home-path/share/dotsteward/manifest.json"
activate_framework_skills
assert_exit 0 run_agents install --generation "$agents_gen"
assert_exit 0 run_e2e --generation "$agents_gen" --json
assert_eq '{"result":"passed","findings":[]}' "$(jq -c . <<<"$DS_STDOUT")"
manifest_edit '.checks.e2e = []'
publish_instance
assert_exit 1 run_e2e --json --keep-going
assert_eq "$(jq -cn --arg home "$HOME" '[
  ["core:commands", "missing-command", "example-term"],
  ["core:agents", "framework-skill-unverifiable", ($home + "/.agents/skills/dotsteward-maintain")],
  ["core:framework-skills", "framework-skill-unverifiable", ($home + "/.agents/skills")]]')" "$(findings)"
assert_eq "" "$(temp_dirs)"
