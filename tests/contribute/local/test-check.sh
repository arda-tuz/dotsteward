# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Q3, `dotsteward contribute check` (SPEC 9.4 steps 4 and 6, 11.3):
#   --expect-fail PATH  the reproduction test must fail before the fix
#   (full gate)         a clean clone on the run's branch with commits after
#                       upstream main; the generic tree scan, the commit
#                       range scan with metadata rules and the denylist, and
#                       the instance-leak scan with terms from `context
#                       --json` (runtime and check identity, remote owner and
#                       repository, private components, settings targets
#                       (not the catalog components' public ones) and
#                       entry ids, instance skills, hostname; shorter than 4
#                       characters, allowlisted or part of the contributor's
#                       public identity: skipped), then `nix flake check`
#                       with the gate's parallelism. Any privacy finding is
#                       exit 4 before Nix runs; findings are redacted; the
#                       run records test_sha and tested_tree only on success;
#                       the terms file is private and removed.
# shellcheck source=tests/contribute/local/helpers.sh
source "$DS_REPO_ROOT/tests/contribute/local/helpers.sh"

setup_owner
write_mirror
start_run add-feature
base=$(git -C "$ct_clone" rev-parse HEAD)

field() {
  state_json | jq -r "$1"
}

# A fresh commit on the fix branch: FILE with CONTENT, after a reset to the
# base.
fresh_commit() {
  git -C "$ct_clone" reset -q --hard "$base"
  clone_commit "$1" "$2" "${3:-feat: change}"
}

expect_privacy_stop() {
  local what=$1
  : >"$DS_CALL_LOG"
  assert_exit 4 run_contribute check
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: privacy hard stop" "$what"
  assert_contains "$DS_STDERR" "nothing may be published" "$what"
  assert_call_count 0 nix 'flake check*'
  assert_eq null "$(field .test_sha)" "test_sha after a privacy stop ($what)"
  assert_eq null "$(field .tested_tree)" "tested_tree after a privacy stop ($what)"
  assert_eq "" "$(temp_leftovers)" "temporary files after a privacy stop ($what)"
}

# --- reproduce (--expect-fail) --------------------------------------------------------

assert_exit 0 run_contribute check --expect-fail tests/example/test-feature.sh
assert_contains "$DS_STDOUT" "[dotsteward] the test fails as expected: tests/example/test-feature.sh"
assert_eq fix "$(field .step)" "step after the reproduction"
assert_call_count 0 nix

assert_exit 1 run_contribute check --expect-fail tests/missing.sh
assert_contains "$DS_STDERR" "[dotsteward] ERROR: no such test in the clone: tests/missing.sh"
for path in ../outside.sh /etc/hostname tests/../../x.sh; do
  assert_exit 1 run_contribute check --expect-fail "$path"
  assert_contains "$DS_STDERR" "[dotsteward] ERROR: the test path must be relative to the clone: $path"
done

# Once the fix exists the test passes: it no longer reproduces anything.
printf 'feature\n' >"$ct_clone/feature.txt"
assert_exit 1 run_contribute check --expect-fail tests/example/test-feature.sh
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the test passes before the fix, so it does not reproduce the problem: tests/example/test-feature.sh"
assert_eq fix "$(field .step)" "step after a passing reproduction"

# --- gate refusals ------------------------------------------------------------

# Uncommitted work: the tested tree would not be a commit.
assert_exit 1 run_contribute check
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the clone $ct_clone has uncommitted changes"
rm -f "$ct_clone/feature.txt"

# No commit after upstream main.
assert_exit 1 run_contribute check
assert_contains "$DS_STDERR" "[dotsteward] ERROR: no commits on fix/add-feature after origin/main"

# Another branch is checked out.
git -C "$ct_clone" switch -q main
assert_exit 1 run_contribute check
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the clone is on main, not on the run's branch fix/add-feature"
git -C "$ct_clone" switch -q fix/add-feature

fresh_commit feature.txt feature 'feat: add the feature'

# The denylist is required in both modes (the pre-push hook needs it too).
rm -f "$ct_denylist"
assert_exit 1 run_contribute check
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the privacy scans need the denylist ~/.config/dotsteward/denylist.txt"
write_denylist
assert_call_count 0 nix
assert_eq null "$(field .test_sha)" "test_sha after the refusals"

# --- privacy hard stops ---------------------------------------------------------

# A denylist term (line 2 of the denylist), reported without the term.
fresh_commit notes.md 'the synthetic-private-term appears here'
expect_privacy_stop denylist
assert_contains "$DS_STDOUT" "denylist:2"
assert_not_contains "$DS_STDOUT$DS_STDERR" "synthetic-private-term"

# A generic finding in the tree: a private address, built at run time.
address=$((190 + 2)).$((160 + 8)).10.20
fresh_commit config.txt "server = $address"
expect_privacy_stop "private address"
assert_contains "$DS_STDOUT" "private-ipv4"
assert_not_contains "$DS_STDOUT$DS_STDERR" "$address"

# A commit with a non-UTC date (metadata rules).
git -C "$ct_clone" reset -q --hard "$base"
printf 'feature\n' >"$ct_clone/feature.txt"
git -C "$ct_clone" add feature.txt
GIT_AUTHOR_DATE='2026-01-01T12:00:00-0700' GIT_COMMITTER_DATE='2026-01-01T12:00:00-0700' \
  git -C "$ct_clone" commit -q -m 'feat: add the feature'
expect_privacy_stop "non-UTC commit"
assert_contains "$DS_STDOUT" "commit-timezone"

# Instance-leak terms from the context.
terms=(alice /home/alice workstation example-term example-term-state example-term-config term-theme term-font
  example-notes "$HOME")
for term in "${terms[@]}"; do
  fresh_commit notes.md "see $term here"
  expect_privacy_stop "instance term $term"
  assert_contains "$DS_STDOUT" "extra-term:" "instance term $term"
  assert_not_contains "$DS_STDOUT$DS_STDERR" "see $term" "redacted instance-leak finding"
done

# The hostname is a term too, unless it is too short or public.
host=$(uname -n)
if ((${#host} >= 4)) && ! grep -qiF -e "$host" "$DS_REPO_ROOT/privacy/allowlist.txt" &&
  [[ dotsteward-test != *"${host,,}"* && $CT_NOREPLY != *"${host,,}"* && example-app != *"${host,,}"* ]]; then
  fresh_commit notes.md "built on $host"
  expect_privacy_stop "hostname"
  assert_contains "$DS_STDOUT" "extra-term:"
fi

# A term in the commit message is caught as well.
git -C "$ct_clone" reset -q --hard "$base"
clone_commit feature.txt feature 'feat: add the feature for example-term'
expect_privacy_stop "instance term in the message"

# --- Nix ----------------------------------------------------------------------

fresh_commit feature.txt feature 'feat: add the feature'
ds_stub_route nix 'flake check*' --exit 1 --stderr 'error: check failed' --times 1
assert_exit 1 run_contribute check
assert_contains "$DS_STDERR" "[dotsteward] ERROR: nix flake check failed in $ct_clone"
assert_eq null "$(field .test_sha)" "test_sha after a failed flake check"
assert_eq fix "$(field .step)" "step after a failed flake check"

# --- pass ---------------------------------------------------------------------

# Short, allowlisted, public-identity and catalog terms are skipped: the
# instance remote owner "bob" (3 characters), the component example-app (in
# the clone's privacy/allowlist.txt), the runtime user dotsteward-test (the
# contributor's GitHub login, already public as the commit author) and the
# settings target herdr-config of the catalog component herdr.
sed -i "s|^remote = .*|remote = \"git@github.com:bob/workstation.git\"|" "$ct_inst/workstation.toml"
fresh_commit feature.txt 'feature by bob for example-app and herdr-config as dotsteward-test' \
  'feat: add the feature'
# The nix stub records the terms file while the check runs.
ds_stub_override nix <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for file in "$TMPDIR"/dotsteward-contribute.*/terms; do
  [[ -f $file ]] || continue
  stat -c %a "$file" >"$DS_TEST_ROOT/terms.mode"
  stat -c %a "$(dirname "$file")" >"$DS_TEST_ROOT/terms-dir.mode"
  cp "$file" "$DS_TEST_ROOT/terms.copy"
done
exit 0
EOF
: >"$DS_CALL_LOG"
assert_exit 0 run_contribute check
head_sha=$(git -C "$ct_clone" rev-parse HEAD)
assert_contains "$DS_STDOUT" "[dotsteward] contribute check passed: ${head_sha:0:12}"
assert_eq 3 "$(grep -c '^\[dotsteward\] scan clean:' <<<"$DS_STDOUT")" "clean scans"
assert_call_count 1 nix "*flake check $ct_clone --no-update-lock-file --keep-going -L --max-jobs 2 --cores 3"
assert_eq "$head_sha" "$(field .test_sha)" "test_sha"
assert_eq "$(git -C "$ct_clone" rev-parse 'HEAD^{tree}')" "$(field .tested_tree)" "tested_tree"
assert_eq trial "$(field .step)" "step after the gate"
assert_eq "" "$(temp_leftovers)" "temporary files after the gate"

# The terms file was private and held the context terms, never the skipped
# ones.
assert_eq 600 "$(<"$DS_TEST_ROOT/terms.mode")" "terms file mode"
assert_eq 700 "$(<"$DS_TEST_ROOT/terms-dir.mode")" "terms directory mode"
for term in alice /home/alice workstation example-term example-term-state example-term-config term-theme \
  term-font example-notes "$HOME"; do
  grep -qxF -e "$term" "$DS_TEST_ROOT/terms.copy" || ds_fail "the terms file lacks [$term]"
done
for term in bob example-app dotsteward-test herdr-config; do
  if grep -qixF -e "$term" "$DS_TEST_ROOT/terms.copy"; then
    ds_fail "the terms file holds the skipped term [$term]"
  fi
done
assert_eq "$(sort -u "$DS_TEST_ROOT/terms.copy" | wc -l)" "$(wc -l <"$DS_TEST_ROOT/terms.copy")" "duplicate terms"

# Checking never pushes.
if network_calls | grep -q 'git-receive-pack'; then
  ds_fail "check pushed: $(network_calls)"
fi
