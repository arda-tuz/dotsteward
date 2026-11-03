# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# The privacy scan cache of vendored skills: outside the sandbox, in a git
# work tree, `static` answers a vendored file (below skills.vendor_dir, a
# regular file no [privacy] file rule selects) from <state root>/privacy/
# scan-cache when an earlier scan found nothing in the same content under
# the same cache key: the scanner's own source and grep, the loaded rules,
# the denylist, the [privacy] exemptions and the instance root. Its path is
# still scanned. The clean line counts the answers ("(K from the scan
# cache)"). A change of the content, of the scanner, of the denylist or of
# the exemptions scans the file again, so a cache hit never hides a new
# finding; a file with any finding (an exempted one too) is never cached. A
# corrupt, foreign or loosely protected cache is ignored, never trusted, and
# rewritten. The cache holds content digests only: never a path, a term, a
# match or the denylist itself. The sandbox and the framework never use it.
# shellcheck source=tests/static/helpers.sh
source "$DS_REPO_ROOT/tests/static/helpers.sh"

inst=$DS_TEST_ROOT/inst
make_instance "$inst"
cache=$DOTSTEWARD_STATE_ROOT/privacy/scan-cache
skills=$inst/agent/skills

# Three more vendored skills; one file of each holds a word that only a later
# denylist term or a later scanner rule matches.
for name in alpha-skill beta-skill gamma-skill; do
  add_skill "$inst" "$name"
done
printf 'Some notes about laterterm in a vendored guide.\n' >"$skills/beta-skill/references/notes.md"
future=EXAMPLE-FUTURE-$(printf '%s' 7531902468)
printf 'token = %s\n' "$future" >"$skills/gamma-skill/references/sample.md"
write_skill_lock "$inst"
mkdir -p "$HOME/private"
denylist=$HOME/private/denylist.txt
printf '# private terms\n%s\n' firstterm >"$denylist"
cat >>"$inst/workstation.toml" <<'TOML'

[privacy]
denylist = "~/private/denylist.txt"
TOML
commit_instance "$inst"
cd "$inst"

# The vendored files: every file below agent/skills.
vendored=$(git -C "$inst" ls-files agent/skills | wc -l)
vendored=$((vendored + 0))
((vendored >= 13)) || ds_fail "expected at least 13 vendored files, found $vendored"

# clean_from_cache: the number of files the clean line answered from the
# cache (fails without a clean line).
clean_from_cache() {
  local line
  line=$(grep -E '^\[dotsteward\] scan clean: [0-9]+ files \([0-9]+ from the scan cache\), 0 commits$' <<<"$DS_STDOUT") ||
    ds_fail "no clean line with a cache count: $DS_STDOUT"
  line=${line#*\(}
  printf '%s\n' "${line%% *}"
}

# no_private_text: neither a term, a planted match nor the denylist path is
# in any file of the state root.
no_private_text() {
  local text
  for text in firstterm laterterm "$future" "$denylist" private/denylist; do
    if grep -rqF -- "$text" "$DOTSTEWARD_STATE_ROOT"; then
      ds_fail "the state root holds private text: $text"
    fi
  done
}

# --- a first scan fills the cache, the next one answers from it -----------------

assert_exit 0 static --only privacy
assert_eq 0 "$(clean_from_cache)"
[[ -f $cache ]] || ds_fail "no scan cache was written: $cache"
assert_file_mode "$DOTSTEWARD_STATE_ROOT/privacy" 700
assert_file_mode "$cache" 600
# Only the header, the key and content digests.
assert_eq "dotsteward privacy scan cache 1" "$(sed -n 1p "$cache")"
[[ $(sed -n 2p "$cache") =~ ^key\ [0-9a-f]{64}$ ]] || ds_fail "unexpected key line: $(sed -n 2p "$cache")"
if sed -n '3,$p' "$cache" | grep -qvE '^[0-9a-f]{64}$'; then
  ds_fail "the cache holds more than digests: $(<"$cache")"
fi
assert_eq "$(sha256_of "$skills/beta-skill/references/notes.md")" \
  "$(grep -xF "$(sha256_of "$skills/beta-skill/references/notes.md")" "$cache")"
no_private_text

assert_exit 0 static --only privacy
assert_eq "$vendored" "$(clean_from_cache)"
assert_eq "" "$DS_STDERR"

# --- content: a changed file is scanned again ------------------------------------

printf 'more harmless text\n' >>"$skills/alpha-skill/references/guide.md"
commit_instance "$inst"
assert_exit 0 static --only privacy
assert_eq "$((vendored - 1))" "$(clean_from_cache)"
assert_exit 0 static --only privacy
assert_eq "$vendored" "$(clean_from_cache)"

# A new finding in a cached file's new content is reported, and the file is
# not cached while it has the finding.
printf 'a firstterm reference\n' >>"$skills/alpha-skill/references/guide.md"
commit_instance "$inst"
assert_exit 1 static --only privacy
assert_contains "$DS_STDOUT" "denylist:2 agent/skills/alpha-skill/references/guide.md:3"
assert_exit 1 static --only privacy
assert_contains "$DS_STDOUT" "denylist:2 agent/skills/alpha-skill/references/guide.md:3"
if grep -qxF "$(sha256_of "$skills/alpha-skill/references/guide.md")" "$cache"; then
  ds_fail "a file with a finding was cached"
fi
no_private_text
# The cache keeps the clean files of the last scan only: the earlier content
# is scanned once more.
git -C "$inst" revert --no-edit HEAD >/dev/null
assert_exit 0 static --only privacy
assert_eq "$((vendored - 1))" "$(clean_from_cache)"

# A path is scanned even when its content comes from the cache.
mkdir -p "$skills/alpha-skill/firstterm-notes"
cp "$skills/alpha-skill/references/guide.md" "$skills/alpha-skill/firstterm-notes/guide.md"
write_skill_lock "$inst"
commit_instance "$inst"
assert_exit 1 static --only privacy
assert_contains "$DS_STDOUT" "denylist:2 path#"
git -C "$inst" revert --no-edit HEAD >/dev/null
assert_exit 0 static --only privacy

# --- the denylist: a new term finds its word in a cached file ----------------------

assert_exit 0 static --only privacy
assert_eq "$vendored" "$(clean_from_cache)"
printf 'laterterm\n' >>"$denylist"
assert_exit 1 static --only privacy
assert_contains "$DS_STDOUT" "denylist:3 agent/skills/beta-skill/references/notes.md:1"
assert_contains "$DS_STDERR" "the scan found 1 finding"
no_private_text
# Without the term the cache of the old denylist is not reused either: the
# key changed twice, so every file is scanned once more.
printf '# private terms\n%s\n' firstterm >"$denylist"
assert_exit 0 static --only privacy
assert_eq 0 "$(clean_from_cache)"
assert_exit 0 static --only privacy
assert_eq "$vendored" "$(clean_from_cache)"

# --- the scanner: a new rule finds its match in a cached file ----------------------

fw=$DS_TEST_ROOT/framework
mkdir -p "$fw"
cp -R "$DS_REPO_ROOT/cli" "$DS_REPO_ROOT/schema" "$DS_REPO_ROOT/VERSION" "$fw/"
python3 - "$fw/cli/lib/privacy.sh" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
anchor = "  secret-aws-key 'AKIA[0-9A-Z]{16}'\n"
assert anchor in text
text = text.replace(anchor, anchor + "  secret-future 'EXAMPLE-FUTURE-[0-9]{10}'\n", 1)
open(path, "w", encoding="utf-8").write(text)
PY
assert_exit 1 "$fw/cli/dotsteward" static --only privacy
assert_contains "$DS_STDOUT" "secret-future agent/skills/gamma-skill/references/sample.md:1"
no_private_text
# The scanner under test keeps its own key.
assert_exit 0 static --only privacy
assert_eq 0 "$(clean_from_cache)"
assert_exit 0 static --only privacy
assert_eq "$vendored" "$(clean_from_cache)"

# --- exemptions: a changed set scans every file again -------------------------------

secret_line=$(printf '%s = %s' "pass""word" "$(fake_secret '' 16)")
printf '%s\n' "$secret_line" >"$skills/alpha-skill/references/client.md"
write_skill_lock "$inst"
commit_instance "$inst"
assert_exit 1 static --only privacy
assert_contains "$DS_STDOUT" "secret-assignment agent/skills/alpha-skill/references/client.md:1"
printf '\n[[privacy.exemptions]]\npath = "agent/skills/alpha-skill/references/client.md"\nrule = "secret-assignment"\nsha256 = "%s"\nreason = "a synthetic example"\n' \
  "$(sha256_of "$skills/alpha-skill/references/client.md")" >>"$inst/workstation.toml"
commit_instance "$inst"
vendored=$((vendored + 1))
assert_exit 0 static --only privacy
assert_eq 0 "$(clean_from_cache)"
assert_contains "$DS_STDOUT" "[dotsteward] 1 finding exempted by [privacy] exemptions"
# The exempted file is scanned every time; every other file is answered.
assert_exit 0 static --only privacy
assert_eq "$((vendored - 1))" "$(clean_from_cache)"
assert_contains "$DS_STDOUT" "[dotsteward] 1 finding exempted by [privacy] exemptions"
if grep -qxF "$(sha256_of "$skills/alpha-skill/references/client.md")" "$cache"; then
  ds_fail "a file with an exempted finding was cached"
fi
no_private_text

# --- a corrupt, foreign or loosely protected cache is ignored ----------------------

good=$(<"$cache")
key_line=$(sed -n 2p "$cache")

# expect_ignored WHAT: the next scan answers nothing from the cache and
# rewrites it as a private regular file.
expect_ignored() {
  assert_exit 0 static --only privacy
  assert_eq 0 "$(clean_from_cache)" "$1"
  [[ -f $cache && ! -L $cache ]] || ds_fail "$1: the cache is not a regular file"
  assert_eq "$good" "$(<"$cache")" "$1: the cache was not rewritten"
  assert_file_mode "$cache" 600
}

printf 'not a cache\n' >"$cache"
expect_ignored "a corrupt cache"

{
  printf '%s\n' "$good"
  printf 'agent/skills/alpha-skill/SKILL.md\n'
} >"$cache"
expect_ignored "a malformed entry"

{
  sed -n 1p <<<"$good"
  printf 'key %064d\n' 0
  sed -n '3,$p' <<<"$good"
} >"$cache"
[[ $(sed -n 2p "$cache") != "$key_line" ]] || ds_fail "the key was not changed"
expect_ignored "a foreign key"

printf '%s\n' "$good" >"$cache"
chmod 0666 "$cache"
expect_ignored "a cache others can write"

printf 'outside\n' >"$DS_TEST_ROOT/elsewhere"
rm -f "$cache"
ln -s "$DS_TEST_ROOT/elsewhere" "$cache"
expect_ignored "a symbolic link"
assert_eq "outside" "$(<"$DS_TEST_ROOT/elsewhere")" "the scan wrote through the symbolic link"

# The cache of another instance root is foreign as well.
other=$DS_TEST_ROOT/other
cp -a "$inst" "$other"
cd "$other"
assert_exit 0 static --only privacy
assert_eq 0 "$(clean_from_cache)"
cd "$inst"
expect_ignored "the cache of another instance"

# --- where the cache is not used ---------------------------------------------------

rm -rf "$DOTSTEWARD_STATE_ROOT/privacy"
assert_exit 0 static --sandbox --only privacy
assert_not_contains "$DS_STDOUT" "scan cache"
[[ ! -e $DOTSTEWARD_STATE_ROOT/privacy ]] || ds_fail "the sandbox scan wrote a cache"
no_private_text
