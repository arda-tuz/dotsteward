# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# `dotsteward contribute check`:
#   --expect-fail PATH  the reproduction test must fail before the fix
#   (full gate)         a clean clone on the run's branch with commits after
#                       upstream main; the generic tree scan, the commit
#                       range scan with metadata rules and the denylist, and
#                       the instance-leak scan with terms from `context
#                       --json` (runtime and check identity, remote owner and
#                       repository, private components, settings targets
#                       (not the catalog components' public ones) and
#                       entry ids, instance skills, hostname; skipped when
#                       shorter than 4 characters, equal to an allowlist
#                       line, part of the contributor's public identity or
#                       already in the content of upstream main outside the
#                       allowlisted strings), then `nix flake check`
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
terms=(/home/alice workstation example-term example-term-state example-term-config term-theme term-font
  example-notes "$HOME")
for term in "${terms[@]}"; do
  fresh_commit notes.md "see $term here"
  expect_privacy_stop "instance term $term"
  assert_contains "$DS_STDOUT" "extra-term:" "instance term $term"
  assert_not_contains "$DS_STDOUT$DS_STDERR" "see $term" "redacted instance-leak finding"
done

# A term inside an allowlisted public string is still a term: the scanner
# masks only the allowlisted string itself.
printf '\n[components.example-grid]\nenable = true\nsource = "instance"\n' >>"$ct_inst/workstation.toml"
fresh_commit notes.md 'see example-grid here'
expect_privacy_stop "instance term inside an allowlist line"
assert_contains "$DS_STDOUT" "extra-term:" "instance term inside an allowlist line"

# The hostname is a term too, unless it is too short, an allowlist line, part
# of the public identity or already published by the upstream.
host=$(uname -n)
if ((${#host} >= 4)) && ! grep -qixF -e "$host" "$ct_clone/privacy/allowlist.txt" &&
  ! git -C "$ct_clone" grep -qiF -e "$host" "$base" -- &&
  [[ dotsteward-test != *"${host,,}"* && $CT_NOREPLY != *"${host,,}"* ]]; then
  fresh_commit notes.md "built on $host"
  expect_privacy_stop "hostname"
  assert_contains "$DS_STDOUT" "extra-term:"
fi

# A term in the commit message is caught as well.
git -C "$ct_clone" reset -q --hard "$base"
clone_commit feature.txt feature 'feat: add the feature for example-term'
expect_privacy_stop "instance term in the message"

# The gate never trusts the privacy configuration of the branch it checks:
# an allowlist line for a leaked term, or a relaxed policy, is itself a hard
# stop (such changes land only in their own, manually reviewed pull request).
fresh_commit notes.md 'see example-notes here'
clone_commit privacy/allowlist.txt "$(cat "$ct_clone/privacy/allowlist.txt")"$'\nexample-notes' \
  'chore: allow a public name'
expect_privacy_stop "allowlisted instance term"
assert_contains "$DS_STDERR" "privacy-config" "allowlisted instance term"
assert_contains "$DS_STDERR" "privacy/allowlist.txt or privacy/policy.toml" "allowlisted instance term"
assert_not_contains "$DS_STDOUT$DS_STDERR" "see example-notes" "allowlisted instance term"
fresh_commit privacy/policy.toml "$(sed 's/^private_ipv4 = true$/private_ipv4 = false/' "$ct_clone/privacy/policy.toml")" \
  'chore: relax the policy'
expect_privacy_stop "relaxed policy"
assert_contains "$DS_STDERR" "privacy-config" "relaxed policy"

# --- Nix ----------------------------------------------------------------------

fresh_commit feature.txt feature 'feat: add the feature'
ds_stub_route nix 'flake check*' --exit 1 --stderr 'error: check failed' --times 1
assert_exit 1 run_contribute check
assert_contains "$DS_STDERR" "[dotsteward] ERROR: nix flake check failed in $ct_clone"
assert_eq null "$(field .test_sha)" "test_sha after a failed flake check"
assert_eq fix "$(field .step)" "step after a failed flake check"

# --- pass ---------------------------------------------------------------------

# Short, allowlisted, public-identity, published and catalog terms are
# skipped: the instance remote owner "bob" (3 characters), the component
# example-app (a line of the clone's privacy/allowlist.txt), the runtime user
# dotsteward-test (the contributor's GitHub login, already public as the
# commit author), the runtime user alice (named by the upstream's
# privacy/policy.toml) and the settings target herdr-config of the catalog
# component herdr. The allowlisted example-grid-public is masked, so the
# component example-grid inside it stays a term without a finding.
sed -i "s|^remote = .*|remote = \"git@github.com:bob/workstation.git\"|" "$ct_inst/workstation.toml"
fresh_commit feature.txt \
  'feature by bob and alice for example-app, example-grid-public and herdr-config as dotsteward-test' \
  'feat: add the feature'
# The nix stub records the terms file while the check runs, then exits with
# STATUS.
nix_records_terms() {
  {
    cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for file in "$TMPDIR"/dotsteward-contribute.*/terms; do
  [[ -f $file ]] || continue
  stat -c %a "$file" >"$DS_TEST_ROOT/terms.mode"
  stat -c %a "$(dirname "$file")" >"$DS_TEST_ROOT/terms-dir.mode"
  cp "$file" "$DS_TEST_ROOT/terms.copy"
done
EOF
    printf 'exit %s\n' "$1"
  } | ds_stub_override nix
}
nix_records_terms 0
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
for term in /home/alice workstation example-term example-grid example-term-state example-term-config term-theme \
  term-font example-notes "$HOME"; do
  grep -qxF -e "$term" "$DS_TEST_ROOT/terms.copy" || ds_fail "the terms file lacks [$term]"
done
for term in bob example-app dotsteward-test alice herdr-config; do
  if grep -qixF -e "$term" "$DS_TEST_ROOT/terms.copy"; then
    ds_fail "the terms file holds the skipped term [$term]"
  fi
done
assert_eq "$(sort -u "$DS_TEST_ROOT/terms.copy" | wc -l)" "$(wc -l <"$DS_TEST_ROOT/terms.copy")" "duplicate terms"

# Checking never pushes.
if network_calls | grep -q 'git-receive-pack'; then
  ds_fail "check pushed: $(network_calls)"
fi

# --- a failed check withdraws an earlier pass ----------------------------------

# Only the latest gate run counts: a privacy stop or a failed flake check on
# the commit that passed before clears test_sha and tested_tree and sends
# the run back to check, so trial and publish refuse it.
write_denylist_lines '# synthetic private terms' 'feature by bob'
expect_privacy_stop "denylist term after a pass"
assert_eq check "$(field .step)" "step after a privacy stop that follows a pass"
write_denylist
assert_exit 0 run_contribute check
assert_eq "$head_sha" "$(field .test_sha)" "test_sha after passing again"
assert_eq trial "$(field .step)" "step after passing again"
nix_records_terms 1
assert_exit 1 run_contribute check
assert_contains "$DS_STDERR" "[dotsteward] ERROR: nix flake check failed in $ct_clone"
assert_eq null "$(field .test_sha)" "test_sha after a failed flake check that follows a pass"
assert_eq null "$(field .tested_tree)" "tested_tree after a failed flake check that follows a pass"
assert_eq check "$(field .step)" "step after a failed flake check that follows a pass"
nix_records_terms 0

# --- terms the upstream already publishes -------------------------------------

# A generic fix of a file that already mentions an instance term in upstream
# main passes: the term is no new leak of the branch, even though the scan
# reads the whole changed file and the commit message names it too.
push_upstream config.sh 'reads workstation.toml' 'feat: read the configuration'
start_run read-config
clone_commit config.sh 'reads workstation.toml once' 'fix: read workstation.toml once'
rm -f "$DS_TEST_ROOT/terms.copy"
assert_exit 0 run_contribute check
assert_contains "$DS_STDOUT" "[dotsteward] contribute check passed: "
if grep -qixF workstation "$DS_TEST_ROOT/terms.copy"; then
  ds_fail "the terms file holds the published term [workstation]"
fi
grep -qxF /home/alice "$DS_TEST_ROOT/terms.copy" || ds_fail "the terms file lacks [/home/alice]"
