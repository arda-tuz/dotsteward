# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# The oracle of an instance script that lists every file of the instance: the helper of the
# instance static scripts (DOTSTEWARD_STATIC_HELPER) prints the files the framework does not own
# (own_files: what git carries, or every file below the root in the sandbox, one per line,
# sorted) and the paths it owns, the ones where its commands create files (framework_paths:
# .dotsteward/, bootstrap.sh, the skills lock, the vendored skills, agent/plugins/,
# agent/skill-licenses/, hosts/ and the settings buffer; a directory ends in /).
# An oracle of the owner's own files built on own_files stays green when a release of the
# framework starts to write a path of its own in the instance, and still fails on a file the
# owner did not expect.
# shellcheck source=tests/static/helpers.sh
source "$DS_REPO_ROOT/tests/static/helpers.sh"

inst=$DS_TEST_ROOT/inst
make_instance "$inst"
mkdir -p "$inst/tests" "$inst/agent/plugins/example-plugin" "$inst/hosts" "$inst/result"
printf '{"name": "example-plugin"}\n' >"$inst/agent/plugins/example-plugin/plugin.json"
printf 'schema_version = 1\n' >"$inst/hosts/laptop1.toml"
printf '{}\n' >"$inst/.dotsteward/manifest.x86_64-linux.json"
printf 'a build output git ignores\n' >"$inst/result/out"
out=$DS_TEST_ROOT/out
mkdir -p "$out"

cat >"$inst/tests/static.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$DOTSTEWARD_STATIC_HELPER"
own_files >"$SCRIPTS_OUT/own"
framework_paths >"$SCRIPTS_OUT/owned"
expected=$(printf '%s\n' .gitignore home.nix home/AGENTS.md scripts/hello.sh scripts/lib.sh tests/static.sh \
  versions.lock.json workstation.toml)
[[ $(own_files) == "$expected" ]] || fail "unexpected own files: $(own_files | tr '\n' ' ')"
SH
chmod 0755 "$inst/tests/static.sh"
printf '\n' >"$inst/home.nix"
printf '\n[gate]\nstatic = ["tests/static.sh"]\n' >>"$inst/workstation.toml"
commit_instance "$inst"
export SCRIPTS_OUT=$out
own=$(printf '%s\n' .gitignore home.nix home/AGENTS.md scripts/hello.sh scripts/lib.sh tests/static.sh \
  versions.lock.json workstation.toml)
cd "$inst"

assert_exit 0 static --only scripts
assert_eq "$(printf '%s\n' .dotsteward/ bootstrap.sh agent/skills.lock.json agent/skills/ agent/plugins/ \
  agent/skill-licenses/ hosts/ local-maintained-files/)" "$(<"$out/owned")" "the paths the framework owns"
assert_eq "$own" "$(<"$out/own")" "the own files in a git work tree"

# A release starts to write a path of its own (the license of a pinned skill), and the settings
# engine captures a new settings file into the buffer: the oracle needs no edit. A file the owner
# adds is still news to it.
mkdir -p "$inst/agent/skill-licenses/example-skill" "$inst/local-maintained-files/files"
printf 'license text\n' >"$inst/agent/skill-licenses/example-skill/LICENSE"
printf '{}\n' >"$inst/local-maintained-files/files/example-settings.json"
commit_instance "$inst"
assert_exit 0 static --only scripts
printf 'a note\n' >"$inst/notes.txt"
assert_exit 1 static --only scripts
assert_contains "$DS_STDERR" "[dotsteward] ERROR: unexpected own files: .gitignore home.nix home/AGENTS.md notes.txt scripts/hello.sh"
rm "$inst/notes.txt"

# The sandbox lists every file below the root, as the Nix check does on its copy of the instance.
sandbox=$DS_TEST_ROOT/sandbox
copy_tree "$inst" "$sandbox"
rm -rf "$sandbox/result"
cd "$sandbox"
assert_exit 0 static --sandbox --only scripts
assert_eq "$own" "$(<"$out/own")" "the own files in the sandbox"
