# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The update allowlist (gate.update_allowlist): in
# the update scope every path changed between the base and the working tree
# (staged, unstaged or committed, deletions included, renames split into
# their two paths) must match one anchored extended regular expression of
# the framework defaults, the component paths of the manifest mirrors or
# gate.update_allowlist; the settings buffer is refused even when an entry
# matches it. The maintain scope has no path restriction. Refusals happen
# before any Nix or step command.
# shellcheck source=tests/cli/gate/helpers.sh
source "$DS_REPO_ROOT/tests/cli/gate/helpers.sh"

ds_use_stubs nix curl
serve_cache

refused() {
  : >"$DS_CALL_LOG"
  assert_exit 1 run_gate "$@"
  assert_eq "" "$DS_STDOUT"
  assert_calls
}

# A path outside the allowlist, unstaged.
printf '# Guide, revised\n' >"$gate_inst/docs/guide.md"
refused
assert_eq "[dotsteward] ERROR: changes outside the update allowlist: docs/guide.md" "$DS_STDERR"
# --scope update is the default.
refused --scope update
assert_contains "$DS_STDERR" "changes outside the update allowlist: docs/guide.md"
# --force bypasses only the memo.
refused --force
assert_contains "$DS_STDERR" "changes outside the update allowlist: docs/guide.md"

# The maintain scope accepts it.
assert_exit 0 run_gate --scope maintain
assert_json "$gate_validation" '.scope == "maintain"'
git -C "$gate_inst" checkout -q -- docs/guide.md

# Committed and staged changes count, and every refused path is listed.
printf 'x\n' >"$gate_inst/README.md"
commit_all "docs: change the readme"
printf 'y\n' >"$gate_inst/home.nix"
git -C "$gate_inst" add home.nix
refused
assert_eq "[dotsteward] ERROR: changes outside the update allowlist: README.md home.nix" "$DS_STDERR"
git -C "$gate_inst" reset -q --hard HEAD~1

# A deletion.
git -C "$gate_inst" rm -q docs/guide.md
refused
assert_eq "[dotsteward] ERROR: changes outside the update allowlist: docs/guide.md" "$DS_STDERR"
git -C "$gate_inst" reset -q --hard HEAD

# The rename hole: a rename into an allowlisted path still reports the
# source path.
mkdir -p "$gate_inst/notes"
git -C "$gate_inst" mv docs/guide.md notes/guide.txt
refused
assert_eq "[dotsteward] ERROR: changes outside the update allowlist: docs/guide.md" "$DS_STDERR"
git -C "$gate_inst" commit -q -m "docs: move the guide"
refused
assert_eq "[dotsteward] ERROR: changes outside the update allowlist: docs/guide.md" "$DS_STDERR"
git -C "$gate_inst" reset -q --hard HEAD~1

# Every framework default, the instance entry and the manifest mirror entry
# pass.
mkdir -p "$gate_inst/agent/skills/example-skill/references" "$gate_inst/notes"
printf '{\n  "nodes": {"root": {}},\n  "version": 7\n}\n' >"$gate_inst/flake.lock"
printf '{ outputs = _: { formatter = { }; }; }\n' >"$gate_inst/flake.nix"
printf '{\n  "schema_version": "1.0",\n  "policy": {}\n}\n' >"$gate_inst/versions.lock.json"
printf '{\n  "schema_version": "1.0",\n  "skills": [1]\n}\n' >"$gate_inst/agent/skills.lock.json"
printf -- '---\nname: example-skill\n---\n' >"$gate_inst/agent/skills/example-skill/SKILL.md"
printf 'guide\n' >"$gate_inst/agent/skills/example-skill/references/guide.md"
jq '.extra = true' "$gate_inst/.dotsteward/manifest.x86_64-linux.json" >"$DS_TEST_ROOT/mirror"
mv "$DS_TEST_ROOT/mirror" "$gate_inst/.dotsteward/manifest.x86_64-linux.json"
printf 'NIX_VERSION=2.35.2\n' >"$gate_inst/.dotsteward/stage0.linux.env"
printf '#!/usr/bin/env bash\n' >"$gate_inst/.dotsteward/cli.sh"
for wrapper in bootstrap.sh rebuild.sh rollback.sh update.sh; do
  printf '#!/usr/bin/env bash\n' >"$gate_inst/$wrapper"
done
printf 'note\n' >"$gate_inst/notes/a.txt"
printf '1.1.0\n' >"$gate_inst/components/example-app/version.txt"
commit_all "chore: update pinned tool versions"
assert_exit 0 run_gate
assert_json "$gate_validation" '.result == "passed" and .scope == "update"'
publish_base

# The entries are anchored at both ends and "/" is not crossed by [^/].
for path in notes/sub/a.txt xflake.lock flake.lock.orig agent/skills/loose.md \
  components/example-app/version.txt.bak .dotsteward/manifest.json; do
  mkdir -p "$(dirname "$gate_inst/$path")"
  printf 'x\n' >"$gate_inst/$path"
  git -C "$gate_inst" add -- "$path"
  refused
  assert_eq "[dotsteward] ERROR: changes outside the update allowlist: $path" "$DS_STDERR"
  git -C "$gate_inst" rm -q --cached -- "$path"
  rm -f -- "${gate_inst:?}/$path"
done

# Configured paths are matched literally: the dots of skills.vendor_dir and
# pins.versions_lock are not wildcards.
mkdir -p "$gate_inst/agent/vendor.skills" "$gate_inst/locks"
git -C "$gate_inst" mv agent/skills/example-skill agent/vendor.skills/example-skill
git -C "$gate_inst" mv versions.lock.json locks/versions.lock.json
set_toml skills vendor_dir '"agent/vendor.skills"'
set_toml pins versions_lock '"locks/versions.lock.json"'
commit_all "chore: move the vendored skills and the versions lock"
publish_base
printf 'changed\n' >"$gate_inst/agent/vendor.skills/example-skill/references/guide.md"
printf '{\n  "schema_version": "1.0",\n  "nix": {}\n}\n' >"$gate_inst/locks/versions.lock.json"
assert_exit 0 run_gate
for path in agent/vendorXskills/example-skill/SKILL.md locks/versionsXlock.json; do
  mkdir -p "$(dirname "$gate_inst/$path")"
  printf 'x\n' >"$gate_inst/$path"
  git -C "$gate_inst" add -- "$path"
  refused
  assert_eq "[dotsteward] ERROR: changes outside the update allowlist: $path" "$DS_STDERR"
  git -C "$gate_inst" rm -q --cached -- "$path"
  rm -f -- "${gate_inst:?}/$path"
done
git -C "$gate_inst" checkout -q -- .

# Every manifest mirror contributes its component paths.
jq -n '{schema_version: 1, system: "aarch64-darwin", update_allowlist: ["components/example-app/darwin\\.txt"]}' \
  >"$gate_inst/.dotsteward/manifest.aarch64-darwin.json"
commit_all "chore: add the darwin mirror"
publish_base
printf 'x\n' >"$gate_inst/components/example-app/darwin.txt"
git -C "$gate_inst" add -A
assert_exit 0 run_gate
git -C "$gate_inst" reset -q --hard HEAD

# The settings buffer is refused in the update scope even when an entry
# matches it, and accepted in the maintain scope.
set_toml gate update_allowlist "['notes/[^/]+\\.txt', 'local-maintained-files/.+']"
commit_all "chore: widen the allowlist"
publish_base
printf 'schema_version = 1\n# changed\n' >"$gate_inst/local-maintained-files/buffer.toml"
mkdir -p "$gate_inst/local-maintained-files/files"
printf 'x\n' >"$gate_inst/local-maintained-files/files/example"
git -C "$gate_inst" add -A
refused
assert_eq "[dotsteward] ERROR: the update scope never changes the settings buffer: local-maintained-files/buffer.toml local-maintained-files/files/example" "$DS_STDERR"
assert_exit 0 run_gate --scope maintain
git -C "$gate_inst" reset -q --hard HEAD

# A configured buffer directory is the one protected.
set_toml settings buffer_dir '"state/buffer"'
set_toml gate update_allowlist "['notes/[^/]+\\.txt', 'state/.+']"
commit_all "chore: move the settings buffer"
publish_base
mkdir -p "$gate_inst/state/buffer" "$gate_inst/state/other"
printf 'x\n' >"$gate_inst/state/buffer/buffer.toml"
printf 'x\n' >"$gate_inst/state/other/file"
git -C "$gate_inst" add -A
refused
assert_eq "[dotsteward] ERROR: the update scope never changes the settings buffer: state/buffer/buffer.toml" "$DS_STDERR"
git -C "$gate_inst" reset -q --hard HEAD

# An invalid entry is an error, not a match.
set_toml gate update_allowlist "['notes/[']"
commit_all "chore: break the allowlist"
publish_base
printf 'x\n' >"$gate_inst/README.md"
refused
assert_contains "$DS_STDERR" "[dotsteward] ERROR: invalid update allowlist: "
