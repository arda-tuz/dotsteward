# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# P3, P4 and P6, update prepare ([gate] I3, I4, I14, I19, I25): the update
# scope needs an entirely clean clone, the maintain scope lists the changes;
# HEAD must equal the freshly fetched origin/<branch> in both scopes; the
# base is recorded atomically in a private candidate.json (schema 1.1) and
# printed as one JSON line. Prepare never runs Nix.
# shellcheck source=tests/cli/update/helpers.sh
source "$DS_REPO_ROOT/tests/cli/update/helpers.sh"

ds_use_stubs nix curl gh
serve_cache

published=$(head_oid)

# --- success ------------------------------------------------------------------

assert_exit 0 run_update prepare --official-sources-only
assert_eq "" "$DS_STDERR"
assert_eq 2 "$(wc -l <<<"$DS_STDOUT")"
assert_eq "[dotsteward] prepared; base OID: $published" "$(head -n 1 <<<"$DS_STDOUT")"
line=$(tail -n 1 <<<"$DS_STDOUT")
assert_eq "$(jq -cn --arg base "$published" --arg root "$up_inst" \
  '{base_oid: $base, root: $root, scope: "update", dirty: [], warnings: []}')" "$line"

# candidate.json: schema 1.1, unchanged fields, private.
assert_file_mode "$up_state" 700
assert_file_mode "$up_candidate" 600
assert_json "$up_candidate" 'keys == ["base_oid", "native_application_updates", "official_sources_only",
  "persistent_agentic_updates", "prepared_at", "root", "schema_version", "scope"]'
assert_json "$up_candidate" '.schema_version == "1.1" and .scope == "update"
  and .official_sources_only == true and .persistent_agentic_updates == false
  and .native_application_updates == true'
assert_json "$up_candidate" '.prepared_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")'
assert_eq "$published" "$(jq -r .base_oid "$up_candidate")"
assert_eq "$up_inst" "$(jq -r .root "$up_candidate")"
# Pretty-printed like every other record.
assert_contains "$(<"$up_candidate")" $'{\n  "schema_version": "1.1",'

# The fetch went through the network wrapper to the configured remote; no
# Nix command ran; nothing was left in TMPDIR or the state directory.
assert_contains "$(network_calls)" "git-upload-pack alice/workstation.git"
assert_call_count 0 nix
assert_eq "" "$(temp_dirs)"
assert_eq "candidate.json" "$(find "$up_state" -mindepth 1 -printf '%f\n')"

# A second prepare replaces the record atomically.
printf 'stale\n' >"$up_candidate"
chmod 0644 "$up_candidate"
assert_exit 0 run_update prepare --official-sources-only --scope maintain
assert_file_mode "$up_candidate" 600
assert_json "$up_candidate" '.scope == "maintain"'
assert_eq "candidate.json" "$(find "$up_state" -mindepth 1 -printf '%f\n')"

# A state directory with a loose mode is made private again.
chmod 0755 "$up_state"
assert_exit 0 run_update prepare --official-sources-only
assert_file_mode "$up_state" 700

# --- P3: a dirty clone ----------------------------------------------------------

refused_dirty() {
  reset_logs
  printf 'keep\n' >"$up_candidate"
  assert_exit 1 run_update prepare --official-sources-only "$@"
  assert_eq "[dotsteward] ERROR: update prepare requires a clean clone" "$DS_STDERR"
  assert_eq "" "$DS_STDOUT"
  assert_no_network
  assert_eq "keep" "$(<"$up_candidate")" "a refused prepare replaced candidate.json"
}

# An untracked file only (the default scope is update).
printf 'new\n' >"$up_inst/new.txt"
refused_dirty
refused_dirty --scope update

# The maintain scope lists the changes instead.
printf 'more\n' >>"$up_inst/docs/guide.md"
reset_logs
assert_exit 0 run_update prepare --official-sources-only --scope maintain
assert_json - '.dirty == [" M docs/guide.md", "?? new.txt"] and .scope == "maintain" and .warnings == []' \
  <<<"$(tail -n 1 <<<"$DS_STDOUT")"
assert_json "$up_candidate" '.scope == "maintain" and .base_oid == "'"$published"'"'
rm -f -- "$up_inst/new.txt"

# A modified file only, then a staged one.
refused_dirty
git -C "$up_inst" add docs/guide.md
refused_dirty
git -C "$up_inst" reset -q --hard

# Ignored files are not changes.
mkdir -p "$up_inst/ignored"
printf 'x\n' >"$up_inst/ignored/file"
assert_exit 0 run_update prepare --official-sources-only
rm -rf -- "$up_inst/ignored"

# The user's status.showUntrackedFiles = no hides nothing: an untracked file
# is still refused in the update scope and listed in the maintain scope.
git config --global status.showUntrackedFiles no
printf 'new\n' >"$up_inst/new.txt"
refused_dirty
reset_logs
assert_exit 0 run_update prepare --official-sources-only --scope maintain
assert_json - '.dirty == ["?? new.txt"]' <<<"$(tail -n 1 <<<"$DS_STDOUT")"
rm -f -- "$up_inst/new.txt"
git config --global --unset status.showUntrackedFiles

# --- P4: HEAD must equal the freshly fetched origin/main --------------------------

# Ahead: a local commit that is not published (both scopes).
change_and_commit "docs: local change"
for scope in update maintain; do
  reset_logs
  printf 'keep\n' >"$up_candidate"
  assert_exit 1 run_update prepare --official-sources-only --scope "$scope"
  assert_eq "[dotsteward] ERROR: local HEAD differs from origin/main; if behind, run 'git pull --ff-only'; if ahead, review the unpublished commits" "$DS_STDERR"
  assert_eq "keep" "$(<"$up_candidate")"
done
git -C "$up_inst" reset -q --hard "$published"

# Behind: the remote moved; the fetch makes origin/main see it.
push_from_elsewhere "docs: change elsewhere"
moved=$(remote_oid)
assert_exit 1 run_update prepare --official-sources-only
assert_contains "$DS_STDERR" "local HEAD differs from origin/main"
assert_eq "$moved" "$(git -C "$up_inst" rev-parse refs/remotes/origin/main)"
git -C "$up_inst" merge -q --ff-only refs/remotes/origin/main
assert_exit 0 run_update prepare --official-sources-only
assert_eq "$moved" "$(jq -r .base_oid "$up_candidate")"
published=$moved

# The fetch fails (no connection): refused without writing the record.
printf 'keep\n' >"$up_candidate"
assert_exit 1 env DS_FAKESSH_FAIL=1 "$DS_REPO_ROOT/cli/dotsteward" --instance "$up_inst" update prepare \
  --official-sources-only
assert_contains "$DS_STDERR" "[dotsteward] ERROR: could not fetch origin/main within 60 s"
assert_eq "keep" "$(<"$up_candidate")"

# The remote has no such branch.
git -C "$up_bare" branch -q -m main trunk
assert_exit 1 run_update prepare --official-sources-only
assert_contains "$DS_STDERR" "[dotsteward] ERROR: could not fetch origin/main within 60 s"
git -C "$up_bare" branch -q -m trunk main

# --- the configured branch ----------------------------------------------------------

git -C "$up_inst" checkout -q -b trunk
set_toml instance branch '"trunk"'
commit_all "chore: use trunk"
git -C "$up_inst" push -q origin trunk 2>/dev/null
trunk=$(head_oid)
reset_logs
assert_exit 0 run_update prepare --official-sources-only
assert_eq "$trunk" "$(jq -r .base_oid "$up_candidate")"
assert_eq "$trunk" "$(git -C "$up_inst" rev-parse refs/remotes/origin/trunk)"
assert_call_count 0 nix
