# shellcheck shell=bash
# Directory digests of the engine are byte-compatible with directory_sha256
# of cli/lib/lib.sh: sorted `sha256sum` lines of the regular files (GNU
# escaping of names with a backslash, newline or carriage return), Python
# bytecode and __pycache__ excluded, symlinks neither hashed nor followed.
# The engine's digest is observed through `pins sync` of repo-owned skills.
# shellcheck source=tests/engines/pins/check/helpers.sh
source "$DS_REPO_ROOT/tests/engines/pins/check/helpers.sh"

pins_instance
z64=$(printf '0%.0s' {1..64})

# add_skill NAME: registers agent/skills/NAME as a repo-owned skill with
# stale digests.
add_skill() {
  json_edit "$skills" "data['skills'].append({'name': '$1', 'directory': '$1', 'revision': 'same-as-instance-checkout', 'skill_sha256': '$z64', 'directory_sha256': '$z64'})"
}

# synced_digest NAME: the directory digest sync writes for skill NAME.
synced_digest() {
  assert_exit 0 pins sync
  jq -r --arg name "$1" '.skills[] | select(.name == $name) | .directory_sha256' "$skills"
}

# The harness skill tree (hidden file, symlinked file, bytecode, non-ASCII
# and space names, empty directory) has a known digest.
json_edit "$skills" "data['skills'][0]['directory_sha256'] = '$z64'"
assert_eq "$DS_FIXTURE_SKILL_TREE_SHA256" "$(synced_digest example-skill)"
assert_eq "$DS_FIXTURE_SKILL_TREE_SHA256" "$(lib_directory_sha256 "$inst/agent/skills/example-skill")"

# Names GNU sha256sum escapes, nested directories, sort order by bytes,
# nested bytecode caches, symlinks to directories and dangling symlinks,
# and a FIFO (not a regular file).
special=$inst/agent/skills/example-special
mkdir -p "$special/a/b" "$special/B" "$special/a/__pycache__" "$special/real-dir" "$special/__pycache__/deep"
printf -- '---\nname: example-special\ndescription: Digest edge cases.\n---\n' >"$special/SKILL.md"
printf 'backslash\n' >"$special/back\\slash.md"
printf 'newline\n' >"$special/new"$'\n'"line.md"
printf 'carriage\n' >"$special/carriage"$'\r'"return.md"
printf 'both\n' >"$special/a/b/mixed\\name"$'\n'".txt"
printf 'nested\n' >"$special/a/b/c.md"
printf 'upper\n' >"$special/B/upper.md"
printf 'lower\n' >"$special/b.md"
printf 'dash\n' >"$special/a-b.md"
printf 'cached\n' >"$special/a/__pycache__/mod.cpython-312.pyc"
printf 'cached\n' >"$special/__pycache__/deep/other.txt"
printf 'bytecode\n' >"$special/a/compiled.pyc"
printf 'bytecode\n' >"$special/.pyc"
printf 'inside\n' >"$special/real-dir/inside.md"
ln -s real-dir "$special/dir-link"
ln -s missing-target "$special/dangling"
ln -s b.md "$special/file-link"
mkfifo "$special/fifo"
add_skill example-special
expected=$(lib_directory_sha256 "$special")
assert_eq "$expected" "$(synced_digest example-special)"

# Every byte of the tree matters: a changed file, a new file, a renamed file.
printf 'changed\n' >>"$special/a/b/c.md"
changed=$(lib_directory_sha256 "$special")
[[ $changed != "$expected" ]] || ds_fail "lib.sh digest did not change"
assert_eq "$changed" "$(synced_digest example-special)"
mv "$special/b.md" "$special/b2.md"
assert_eq "$(lib_directory_sha256 "$special")" "$(synced_digest example-special)"

# A tree whose other content is excluded hashes like SKILL.md alone; a
# missing file is an error naming it.
mkdir -p "$inst/agent/skills/example-empty/__pycache__"
printf -- '---\nname: example-empty\n---\n' >"$inst/agent/skills/example-empty/SKILL.md"
printf 'bytecode\n' >"$inst/agent/skills/example-empty/__pycache__/x.pyc"
add_skill example-empty
assert_eq "$(lib_directory_sha256 "$inst/agent/skills/example-empty")" "$(synced_digest example-empty)"
rm "$inst/agent/skills/example-empty/SKILL.md"
assert_exit 1 pins sync
assert_eq "[pins] ERROR: core/skill-digests: cannot read agent/skills/example-empty/SKILL.md: No such file or directory" \
  "$DS_STDERR"
