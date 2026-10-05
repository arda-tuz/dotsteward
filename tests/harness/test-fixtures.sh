# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Shared fixtures stay internally consistent, and the run-time fixture
# builders produce exactly the documented trees.

common=$DS_REPO_ROOT/tests/fixtures/common

# --- committed fixtures -------------------------------------------------------
# Every JSON fixture parses.
while IFS= read -r -d '' file; do
  jq -e . "$file" >/dev/null || ds_fail "invalid JSON: $file"
done < <(find "$common" -name '*.json' -print0)

# The APT index describes the committed package files byte for byte.
entries=0
while IFS='|' read -r filename size sha; do
  entries=$((entries + 1))
  file=$common/debs/$(basename "$filename")
  [[ -f $file ]] || ds_fail "Packages names a missing file: $filename"
  assert_eq "$size" "$(stat -c %s "$file")" "size of $filename"
  assert_eq "$sha" "$(sha256sum "$file" | cut -d' ' -f1)" "SHA256 of $filename"
done < <(awk -F': ' '
  /^Filename: / { f = $2 } /^Size: / { s = $2 } /^SHA256: / { h = $2 }
  /^$/ { print f "|" s "|" h; f = s = h = "" }
  END { if (f != "") print f "|" s "|" h }' "$common/apt/Packages")
assert_eq 4 "$entries" "Packages entries"
assert_eq "$(find "$common/debs" -name '*.deb' | wc -l)" "$entries" "one entry per package file"

# Release assets match the files they describe.
release=$common/github/release-latest.json
deb=$common/debs/example-term_0.9.0_amd64.deb
assert_json "$release" '.tag_name == "v0.9.0" and .draft == false and .prerelease == false'
assert_json "$release" ".assets[0].size == $(stat -c %s "$deb")"
assert_json "$release" ".assets[0].digest == \"sha256:$(sha256sum "$deb" | cut -d' ' -f1)\""
assert_json "$release" ".assets[1].digest == \"sha256:$(sha256sum "$common/github/SHA256SUMS" | cut -d' ' -f1)\""
(cd "$common/debs" && sha256sum --quiet -c "$common/github/SHA256SUMS") || ds_fail "SHA256SUMS does not verify"
assert_json "$common/github/releases.json" '[.[] | select(.draft | not) | select(.prerelease | not) | .tag_name] == ["v0.9.0", "v0.8.0"]'
assert_json "$common/github/compare.json" '.status == "ahead" and .ahead_by == (.commits | length)'
assert_json "$common/vscode/update-latest.json" '(.sha256hash | test("^[0-9a-f]{64}$")) and (.version | test("^[0-9a-f]{40}$")) and .productVersion == .name'
[[ $(<"$common/nix/install.sha256") =~ ^[0-9a-f]{64}$ ]] || ds_fail "install.sha256 is not one hex digest"
assert_json "$common/npm/example-app.json" '.versions[."dist-tags".latest].dist.integrity | startswith("sha512-")'
for release_file in "$common"/os-release/*; do
  # shellcheck disable=SC1090 # the fixture is a shell-compatible key file
  (source "$release_file" && [[ -n $ID && -n $VERSION_ID ]]) || ds_fail "unreadable os-release: $release_file"
done

# --- skill tree builder ---------------------------------------------------------
# The reference directory digest (the algorithm of lib.sh directory_sha256,
# vendored here so the fixture does not depend on the code under test).
reference_directory_sha256() {
  (
    cd -- "$1" || exit
    find . \( -type d -name __pycache__ -prune \) -o \( -type f ! -name '*.pyc' -print0 \) |
      LC_ALL=C sort -z | xargs -0 -r sha256sum
  ) | sha256sum | awk '{print $1}'
}

ds_fixture_skill_tree "$TMPDIR/skill"
tree=$TMPDIR/skill
assert_contains "$(<"$tree/SKILL.md")" "name: example-skill"
[[ -f $tree/.hidden-config ]] || ds_fail "hidden file missing"
assert_file_mode "$tree/scripts/run.sh" 0755
assert_file_mode "$tree/scripts/private.txt" 0600
assert_file_mode "$tree/references" 0750
[[ -f $tree/__pycache__/helper.cpython-312.pyc && -f $tree/scripts/helper.pyc ]] || ds_fail "bytecode files missing"
[[ -f $tree/$'caf\xc3\xa9.md' && -f "$tree/with space.md" ]] || ds_fail "unusual file names missing"
assert_symlink_to "$tree/link.md" references/guide.md
[[ -d $tree/empty && -z $(ls -A "$tree/empty") ]] || ds_fail "empty directory missing"
assert_eq "$DS_FIXTURE_SKILL_TREE_SHA256" "$(reference_directory_sha256 "$tree")"
# The digest ignores bytecode, so new bytecode does not change it; content does.
printf 'more bytecode' >"$tree/__pycache__/other.pyc"
assert_eq "$DS_FIXTURE_SKILL_TREE_SHA256" "$(reference_directory_sha256 "$tree")"
printf 'changed\n' >>"$tree/references/guide.md"
[[ $(reference_directory_sha256 "$tree") != "$DS_FIXTURE_SKILL_TREE_SHA256" ]] || ds_fail "digest ignores content"
# The skill name is a parameter.
ds_fixture_skill_tree "$TMPDIR/other" other-skill
assert_contains "$(<"$TMPDIR/other/SKILL.md")" "name: other-skill"
assert_exit 1 ds_fixture_skill_tree "$TMPDIR/other"
assert_contains "$DS_STDERR" "already exists"

# --- backup layouts builder ---------------------------------------------------
state=$TMPDIR/state
ds_fixture_backup_layouts "$state"
backups=$state/backups
assert_file_mode "$backups" 0700
assert_eq "20251231T000000Z 20260101T000000Z 20260102T000000Z 20260102T000000Z-adopt 20260103T000000Z-skills 20260104T000000Z-pre-local-maintained-files 20260105T000000Z" \
  "$(cd "$backups" && printf '%s ' * | sed 's/ $//')"
assert_eq "20260102T000000Z-adopt" "$(<"$backups/20260102T000000Z-adopt/files$HOME/.zshrc")"
assert_file_mode "$backups/20260102T000000Z-adopt/files$HOME/.zshrc" 0600
assert_file_mode "$backups/20260102T000000Z-adopt" 0700
assert_eq "20251231T000000Z" "$(<"$backups/20251231T000000Z/files/home/.codex/AGENTS.md")"
assert_eq "20260104T000000Z-pre-local-maintained-files" \
  "$(<"$backups/20260104T000000Z-pre-local-maintained-files/${HOME#/}/.config/example-term/config.toml")"
[[ -L $backups/20260105T000000Z/files$HOME/.config/link ]] || ds_fail "dangling link copy missing"

# The documented newest-copy answers, with the reference lookup (current
# layout, then the legacy files/home/<relative> layout, newest name first).
reference_backup_copy_of() {
  local target=$1 dir candidate
  while IFS= read -r dir; do
    for candidate in "$dir/files$target" "$dir/files/home/${target#"$HOME"/}"; do
      [[ -f $candidate && ! -L $candidate ]] && { printf '%s\n' "$candidate"; return 0; }
    done
  done < <(find "$backups" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort -r)
  return 1
}
assert_eq "$backups/20260102T000000Z-adopt/files$HOME/.zshrc" "$(reference_backup_copy_of "$HOME/.zshrc")"
assert_eq "$backups/20251231T000000Z/files/home/.codex/AGENTS.md" "$(reference_backup_copy_of "$HOME/.codex/AGENTS.md")"
assert_exit 1 reference_backup_copy_of "$HOME/.config/link"
