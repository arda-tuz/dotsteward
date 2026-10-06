# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# shellcheck disable=SC2016 # fixture text with a literal $ is written on purpose
# Instance privacy policy (SPEC 11.2): `static` scans an instance with the
# generic secret rules, [privacy] forbidden_paths, file_rules and the
# optional denylist (outside the sandbox only); the framework-only rules
# (non-ASCII text, home paths, e-mail addresses, private IPv4 addresses and
# the commit rules) do not apply. Library level: the instance policy and
# file rules of cli/lib/privacy.sh in tree and range scans.
# shellcheck source=tests/static/helpers.sh
source "$DS_REPO_ROOT/tests/static/helpers.sh"

inst=$DS_TEST_ROOT/inst
make_instance "$inst"
mkdir -p "$inst/profiles/viewer" "$inst/runs/2026"
cat >>"$inst/workstation.toml" <<'TOML'

[privacy]
forbidden_paths = ["*notes-private*", "drafts/**"]
denylist = "~/private/denylist.txt"

[[privacy.file_rules]]
files = ["profiles/example/*rc"]
pattern = '(\[recent items\]|/home/[^/]+/(Documents|Downloads)/)'
message = "viewer profile contains personal history"
TOML
printf '[General]\nzoom=100\n' >"$inst/profiles/example/example.ini"
commit_instance "$inst"
mkdir -p "$HOME/private"
printf '# private terms\n%s\n' "secretproject" >"$HOME/private/denylist.txt"
cd "$inst"

assert_exit 0 static --only privacy
assert_contains "$DS_STDOUT" "[dotsteward] scan clean:"

# Each instance rule fires; findings are redacted.
printf '[recent items]\nitem1=/home/%s/notes/a.txt\n' someone >>"$inst/profiles/example/example.ini"
printf 'notes\n' >"$inst/my-notes-private.md"
printf 'out\n' >"$inst/runs/2026/out.txt"
printf 'about SecretProject\n' >"$inst/home/notes.txt"
printf '%s: %s\n' "pass""word" "$(fake_secret '' 12)" >"$inst/home/creds.txt"
assert_exit 1 static --only privacy
assert_contains "$DS_STDOUT" "file-rule:1 profiles/example/example.ini:3 (viewer profile contains personal history)"
assert_contains "$DS_STDOUT" "file-rule:1 profiles/example/example.ini:4 (viewer profile contains personal history)"
assert_contains "$DS_STDOUT" "forbidden-path my-notes-private.md (path)"
assert_contains "$DS_STDOUT" "forbidden-path runs/2026/out.txt (path)"
assert_contains "$DS_STDOUT" "denylist:2 home/notes.txt:1"
assert_contains "$DS_STDOUT" "secret-assignment home/creds.txt:1"
assert_not_contains "$DS_STDOUT" "home-path"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: static privacy: the scan found 6 findings"
assert_not_contains "$DS_STDOUT$DS_STDERR" "SecretProject"
assert_not_contains "$DS_STDOUT$DS_STDERR" "Documents/a.pdf"

# The sandbox has no denylist (no home directory); the other rules apply.
assert_exit 1 static --sandbox --only privacy
assert_not_contains "$DS_STDOUT" "denylist:"
assert_contains "$DS_STDOUT" "forbidden-path my-notes-private.md (path)"

# A configured denylist that cannot be read is an error outside the sandbox.
rm "$inst/my-notes-private.md" "$inst/home/notes.txt" "$inst/home/creds.txt" "$inst/profiles/example/example.ini"
rm -r "$inst/runs"
assert_exit 0 static --only privacy
mv "$HOME/private/denylist.txt" "$HOME/private/moved.txt"
assert_exit 1 static --only privacy
assert_contains "$DS_STDERR" "[dotsteward] ERROR: static privacy: denylist file is missing or unreadable: ~/private/denylist.txt"
assert_exit 0 static --sandbox --only privacy

# --- library: ds_privacy_load_instance_policy and file rules -----------------
# shellcheck source=cli/lib/privacy.sh
source "$DS_REPO_ROOT/cli/lib/privacy.sh"

lib=$DS_TEST_ROOT/lib
mkdir -p "$lib/conf" "$lib/plans"
git init -q "$lib"
printf 'Theme=dark\n' >"$lib/conf/app.ini"
printf 'caf\xc3\xa9 someone@%s 10.%s.0.1\n' example.net 1 >"$lib/notes.txt"
git -C "$lib" add -A
git -C "$lib" commit -q -m "test: base"
printf 'LastOpened=/srv/x\n' >>"$lib/conf/app.ini"
printf 'draft\n' >"$lib/plans/one.md"
git -C "$lib" add -A
git -C "$lib" commit -q -m "test: change"

# run_scan MODE...: collects and reports with the instance policy (forbidden
# plans/**, one file rule on conf/*.ini) in a subshell.
run_scan() {
  (
    ds_privacy_load_instance_policy
    ds_privacy_add_forbidden_path 'plans/**'
    ds_privacy_add_file_rule "app history recorded" 'lastopened=' 'conf/*.ini'
    ds_privacy_begin
    trap ds_privacy_end EXIT
    case $1 in
      tree) ds_privacy_collect_tree "$lib" 1 ;;
      range) ds_privacy_collect_range "$lib" "$2" ;;
    esac
    ds_privacy_report 1 0
    printf 'findings=%s\n' "$DS_PRIVACY_FINDINGS"
  )
}

out=$(run_scan tree)
assert_contains "$out" "file-rule:1 conf/app.ini:2 (app history recorded)"
assert_contains "$out" "forbidden-path plans/one.md (path)"
assert_contains "$out" "findings=2"
assert_not_contains "$out" "non-ascii"
assert_not_contains "$out" "email"
assert_not_contains "$out" "private-ipv4"

out=$(run_scan range HEAD~1..HEAD)
assert_contains "$out" "file-rule:1 commit $(git -C "$lib" rev-parse --short=12 HEAD) conf/app.ini:2 (app history recorded)"
assert_contains "$out" "findings=2"

# Invalid file rules are refused with their number, never silently ignored.
assert_exit 1 bash -c 'source "$1"; ds_privacy_load_instance_policy; ds_privacy_add_file_rule msg "(unclosed" "x"' \
  _ "$DS_REPO_ROOT/cli/lib/privacy.sh"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: privacy file rule 1: invalid regular expression"
assert_exit 1 bash -c 'source "$1"; ds_privacy_load_instance_policy; ds_privacy_add_file_rule msg "x"' \
  _ "$DS_REPO_ROOT/cli/lib/privacy.sh"
assert_contains "$DS_STDERR" "privacy file rule 1: no file globs"
