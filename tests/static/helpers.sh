# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Helpers shared by the static contract tests. Not a test file (no test-
# prefix).
#
# `dotsteward static` checks this directory too (framework mode): every
# string that must break a contract (secrets, banned command lines, unknown
# command names) is assembled at run time from fragments.

DS_CLI=$DS_REPO_ROOT/cli/dotsteward

# static [ARG...]: `dotsteward static` in the current directory.
static() {
  "$DS_CLI" static "$@"
}

# sha256_of FILE: the hex digest.
sha256_of() {
  sha256sum -- "$1" | awk '{print $1}'
}

# dir_sha256_of DIR: the directory digest of lib.sh directory_sha256 (sorted
# sha256sum lines of the regular files, __pycache__ and *.pyc excluded).
dir_sha256_of() {
  (
    cd -- "$1" || exit 1
    find . \( -type d -name __pycache__ -prune \) -o \( -type f ! -name '*.pyc' -print0 \) |
      LC_ALL=C sort -z | xargs -0 -r sha256sum
  ) | sha256sum | awk '{print $1}'
}

# write_skill_lock INSTANCE: rewrites agent/skills.lock.json from the skill
# directories below agent/skills (name = directory name).
write_skill_lock() {
  local root=$1 dir name entries=() count=0
  for dir in "$root"/agent/skills/*/; do
    [[ -d $dir ]] || continue
    dir=${dir%/}
    name=${dir##*/}
    entries+=("$(jq -n --arg name "$name" --arg sha "$(sha256_of "$dir/SKILL.md")" \
      --arg dsha "$(dir_sha256_of "$dir")" \
      '{name: $name, directory: $name, skill_sha256: $sha, directory_sha256: $dsha}')")
    count=$((count + 1))
  done
  printf '%s\n' "${entries[@]}" | jq -s --argjson count "$count" \
    '{schema_version: "1.0", expected_skill_count: $count, skills: .}' >"$root/agent/skills.lock.json"
}

# add_skill INSTANCE NAME: a vendored skill with SKILL.md and LICENSE; the
# lock is not updated (call write_skill_lock).
add_skill() {
  local dir=$1/agent/skills/$2
  mkdir -p "$dir/references"
  printf -- '---\nname: %s\ndescription: Synthetic skill for dotsteward tests.\n---\n\n# %s\n' "$2" "$2" >"$dir/SKILL.md"
  printf 'MIT License\n\nSynthetic license text.\n' >"$dir/LICENSE"
  printf '# Guide\n' >"$dir/references/guide.md"
}

# make_instance DIR: a synthetic instance that satisfies every instance
# contract, committed to a fresh git repository. Extra configuration is
# appended to DIR/workstation.toml by the tests (whole tables only).
make_instance() {
  local root=$1
  mkdir -p "$root"/{.dotsteward,scripts,agent/skills,home,local-maintained-files}
  cat >"$root/workstation.toml" <<'TOML'
schema_version = 1

[identity]
username = "alice"

[instance]
remote = "git@github.com:alice/workstation.git"

[nix]
state_version = "26.05"

[profiles]
names = ["workstation"]
TOML
  cat >"$root/versions.lock.json" <<'JSON'
{
  "schema_version": "1.0",
  "generated_at": "2026-01-01T00:00:00+00:00",
  "policy": {
    "official_sources_only": true,
    "persistent_agentic_updates": false,
    "scheduled_repository_updates": false,
    "native_application_updates": true,
    "major_version_review_required": true
  },
  "nix_packages": {}
}
JSON
  cp "$DS_REPO_ROOT/template/.dotsteward/cli.sh" "$root/.dotsteward/cli.sh"
  if [[ -f $DS_REPO_ROOT/template/bootstrap.sh ]]; then
    cp "$DS_REPO_ROOT/template/bootstrap.sh" "$root/bootstrap.sh"
  fi
  printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf '\''hello\\n'\''\n' >"$root/scripts/hello.sh"
  chmod 0755 "$root/scripts/hello.sh"
  printf '# shellcheck shell=bash\ngreet() {\n  printf '\''hi\\n'\''\n}\n' >"$root/scripts/lib.sh"
  printf '# Agent rules\n\nSynthetic rules.\n' >"$root/home/AGENTS.md"
  printf 'schema_version = 1\n' >"$root/local-maintained-files/buffer.toml"
  printf 'result\nresult-*\n*.log\n' >"$root/.gitignore"
  add_skill "$root" example-skill
  write_skill_lock "$root"
  git init -q "$root"
  commit_instance "$root"
}

# commit_instance DIR: commits every change.
commit_instance() {
  git -C "$1" add -A
  git -C "$1" commit -q --allow-empty -m "test: update instance"
}

# copy_tree SRC DEST: copies SRC without .git directories, Python bytecode
# and Nix result links (what the Nix sandbox sees).
copy_tree() {
  mkdir -p "$2"
  tar -C "$1" --exclude=.git --exclude=__pycache__ --exclude='*.pyc' --exclude='./result*' -cf - . |
    tar -C "$2" -xf -
}

# framework_copy DEST: a copy of the framework source under test; its own
# cli/dotsteward checks it in framework mode when run inside it.
framework_copy() {
  copy_tree "$DS_REPO_ROOT" "$1"
}

# fw_static DIR [ARG...]: `dotsteward static` of the framework copy DIR,
# run inside DIR.
fw_static() {
  local dir=$1
  shift
  (cd "$dir" && ./cli/dotsteward static "$@")
}

# Fragments of strings that break a contract when joined at run time.
# shellcheck disable=SC2034 # read by the test files that source this file
{
  BAN_FETCH=cu"rl"
  BAN_PUSH="git pu""sh"
  BAN_FORCE=--for"ce"
  BAN_DOWNGRADE=--allow-down"grades"
}
