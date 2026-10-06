# shellcheck shell=bash
# shellcheck disable=SC2016 # backticks and $ are literal Markdown and expected messages
# shellcheck disable=SC2153 # DS_REPO_ROOT comes from tests/lib/harness.sh
# C9 and tools/gen-skills-manifest.sh: skills/manifest.json lists every
# skill directory with the sha256 of SKILL.md and the directory digest of
# cli/lib/lib.sh, sorted by name; --check refuses a stale or missing file.
# shellcheck source=tests/skills/selftest/helpers.sh
source "$DS_REPO_ROOT/tests/skills/selftest/helpers.sh"
# shellcheck source=cli/lib/lib.sh
source "$DS_REPO_ROOT/cli/lib/lib.sh"

gen=$DS_REPO_ROOT/tools/gen-skills-manifest.sh
root=$SC_REPO_ROOT
manifest=$root/skills/manifest.json
beta=$(st_skill beta-skill)
alpha=$(st_skill alpha-skill)
# A bytecode cache does not change the digest (directory_sha256 skips it).
mkdir -p "$alpha/__pycache__"
printf 'bytecode' >"$alpha/__pycache__/x.pyc"

# Without a manifest, --check fails and names the fix.
assert_exit 1 bash "$gen" --check --root "$root"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: skills/manifest.json is missing; run tools/gen-skills-manifest.sh"
st_expect_finding 'C9 skills/manifest.json: is missing; run tools/gen-skills-manifest.sh' \
  sc_check_manifest "$root" alpha-skill beta-skill

# Writing: the exact document, sorted by name, jq-formatted.
assert_exit 0 bash "$gen" --root "$root"
assert_eq '[dotsteward] wrote skills/manifest.json (2 skills)' "$DS_STDOUT"
expected=$(jq -n \
  --arg a_skill "$(sha256_file "$alpha/SKILL.md")" --arg a_dir "$(directory_sha256 "$alpha")" \
  --arg b_skill "$(sha256_file "$beta/SKILL.md")" --arg b_dir "$(directory_sha256 "$beta")" \
  '{schema_version: 1, skills: [
     {name: "alpha-skill", directory: "alpha-skill", skill_sha256: $a_skill, directory_sha256: $a_dir},
     {name: "beta-skill", directory: "beta-skill", skill_sha256: $b_skill, directory_sha256: $b_dir}]}')
assert_eq "$expected" "$(<"$manifest")"
assert_file_mode "$manifest" 644
[[ $(tail -c 1 "$manifest" | od -An -c | tr -d ' ') == '\n' ]] || ds_fail "the manifest must end with a newline"
before=$(sha256sum "$manifest")

# --check passes, a second run changes nothing, and the contract check is
# clean for the expected set only.
assert_exit 0 bash "$gen" --check --root "$root"
assert_eq '[dotsteward] skills/manifest.json is up to date (2 skills)' "$DS_STDOUT"
assert_exit 0 bash "$gen" --root "$root"
assert_eq '[dotsteward] skills/manifest.json is up to date (2 skills)' "$DS_STDOUT"
assert_eq "$before" "$(sha256sum "$manifest")"
st_expect_clean sc_check_manifest "$root" beta-skill alpha-skill
st_expect_finding 'C9 skills/manifest.json: skills [alpha-skill beta-skill] differ from the expected [alpha-skill]' \
  sc_check_manifest "$root" alpha-skill

# Any content change makes it stale: a reference, a new file, SKILL.md.
printf 'more\n' >>"$beta/references/commands.md"
assert_exit 1 bash "$gen" --check --root "$root"
assert_contains "$DS_STDERR" '[dotsteward] ERROR: skills/manifest.json is stale; run tools/gen-skills-manifest.sh'
st_expect_finding 'C9 skills/manifest.json: is stale; run tools/gen-skills-manifest.sh' \
  sc_check_manifest "$root" alpha-skill beta-skill
assert_eq "$before" "$(sha256sum "$manifest")" "--check never writes"
bash "$gen" --root "$root" >/dev/null
assert_exit 0 bash "$gen" --check --root "$root"
printf 'new\n' >"$alpha/references/new.md"
assert_exit 1 bash "$gen" --check --root "$root"
bash "$gen" --root "$root" >/dev/null
printf '\n' >>"$alpha/SKILL.md"
assert_exit 1 bash "$gen" --check --root "$root"
bash "$gen" --root "$root" >/dev/null
assert_json "$manifest" ".skills[0].skill_sha256 == \"$(sha256_file "$alpha/SKILL.md")\""

# Regular files next to the skills are ignored; refusals leave the manifest
# untouched.
printf 'notes\n' >"$root/skills/README.md"
assert_exit 0 bash "$gen" --check --root "$root"
before=$(sha256sum "$manifest")
mkdir "$root/skills/gamma-skill"
assert_exit 1 bash "$gen" --root "$root"
assert_eq '[dotsteward] ERROR: skills/gamma-skill: SKILL.md is missing or not a regular file' "$DS_STDERR"
ln -s ../alpha-skill/SKILL.md "$root/skills/gamma-skill/SKILL.md"
assert_exit 1 bash "$gen" --root "$root"
assert_eq '[dotsteward] ERROR: skills/gamma-skill: SKILL.md is missing or not a regular file' "$DS_STDERR"
rm -r "$root/skills/gamma-skill"
ln -s alpha-skill "$root/skills/gamma-skill"
assert_exit 1 bash "$gen" --root "$root"
assert_eq '[dotsteward] ERROR: skills/gamma-skill: a skill directory must not be a symlink' "$DS_STDERR"
rm "$root/skills/gamma-skill"
ln -s SKILL.md "$alpha/alias.md"
assert_exit 1 bash "$gen" --root "$root"
assert_eq '[dotsteward] ERROR: skills/alpha-skill/alias.md: symlinks are not allowed in a skill (directory digests ignore them)' "$DS_STDERR"
rm "$alpha/alias.md"
assert_eq "$before" "$(sha256sum "$manifest")"

# An empty skills directory gives an empty list; a missing one is an error.
empty=$DS_TEST_ROOT/empty
mkdir -p "$empty/skills"
assert_exit 0 bash "$gen" --root "$empty"
assert_eq '{"schema_version":1,"skills":[]}' "$(jq -c . "$empty/skills/manifest.json")"
assert_exit 1 bash "$gen" --root "$DS_TEST_ROOT/nowhere"
assert_eq "[dotsteward] ERROR: no skills directory: $DS_TEST_ROOT/nowhere/skills" "$DS_STDERR"

# Usage errors.
assert_exit 1 bash "$gen" --bogus
assert_contains "$DS_STDERR" 'unknown option: --bogus'
assert_exit 1 bash "$gen" --root
assert_contains "$DS_STDERR" '--root requires a directory'
assert_exit 0 bash "$gen" --help
assert_contains "$DS_STDOUT" 'Usage: tools/gen-skills-manifest.sh [--check] [--root DIR]'

# The default root is the framework checkout that holds the script.
copy=$DS_TEST_ROOT/framework
mkdir -p "$copy/tools" "$copy/cli/lib" "$copy/skills"
cp "$gen" "$copy/tools/"
cp "$DS_REPO_ROOT"/cli/lib/*.sh "$copy/cli/lib/"
st_skill delta-skill "$copy/skills" >/dev/null
(cd "$DS_TEST_ROOT" && bash "$copy/tools/gen-skills-manifest.sh" >/dev/null)
assert_json "$copy/skills/manifest.json" '[.skills[].name] == ["delta-skill"]'
