# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The canonical checkout after a successful update publish:
# the canonical checkout is canonical_repo of
# <state root>/host-overrides/inventory.json (written by rebuild) when it is
# set, else instance.checkout (default ~/<instance.name>). A clean clone of
# instance.remote on instance.branch sitting exactly at the base is
# fast-forwarded to the published commit; any other state is a warning, and
# a failed fast-forward is a warning: neither fails the publish. A canonical
# path that is not a git repository (an inventory path included, which
# never falls back) or that is the publishing clone itself is skipped
# silently.
# shellcheck source=tests/cli/update/helpers.sh
source "$DS_REPO_ROOT/tests/cli/update/helpers.sh"

ds_use_stubs nix curl gh
serve_cache

inventory=$DOTSTEWARD_STATE_ROOT/host-overrides/inventory.json
# The default instance.checkout: ~/<instance.name>, the name being the
# directory name of the instance.
canon=$HOME/instance

# clone_canonical DIR: a clone of the remote at the current remote main,
# with origin set to the configured remote URL.
clone_canonical() {
  rm -rf -- "$1"
  git clone -q "$up_bare" "$1"
  git -C "$1" remote set-url origin "$UP_REMOTE"
}

# candidate: prepares, commits a change and validates it; sets base.
candidate() {
  assert_exit 0 run_update prepare --official-sources-only --scope maintain
  base=$(head_oid)
  change_and_commit "docs: change $RANDOM"
  write_validation
}

# published_with_warning: publish passed, printed the canonical warning for
# DIR and left DIR at the base.
published_with_warning() {
  local dir=$1
  reset_logs
  assert_exit 0 run_update publish --scope maintain
  assert_eq "$(head_oid)" "$(remote_oid)"
  assert_eq "[dotsteward] WARNING: canonical checkout is not a clean clone of $UP_REMOTE on main at the base OID $base; inspect it and run 'git pull --ff-only': $dir" \
    "$(grep -F '[dotsteward]' <<<"$DS_STDERR")"
  assert_eq "[dotsteward] published $(head_oid) to main without force; publishing does not activate the local system" \
    "$DS_STDOUT"
  assert_eq "$base" "$(git -C "$dir" rev-parse HEAD)"
}

# published_silently: publish passed without a word about a canonical
# checkout.
published_silently() {
  reset_logs
  assert_exit 0 run_update publish --scope maintain
  assert_eq "$(head_oid)" "$(remote_oid)"
  assert_eq "[dotsteward] published $(head_oid) to main without force; publishing does not activate the local system" \
    "$DS_STDOUT"
  assert_not_contains "$DS_STDERR" "[dotsteward]"
}

# --- fast-forward -------------------------------------------------------------------

clone_canonical "$canon"
candidate
reset_logs
assert_exit 0 run_update publish --scope maintain
head=$(head_oid)
assert_eq "$head" "$(remote_oid)"
assert_eq "$head" "$(git -C "$canon" rev-parse HEAD)"
assert_eq "" "$(git -C "$canon" status --porcelain)"
assert_eq "[dotsteward] canonical checkout fast-forwarded to the published commit: $canon
[dotsteward] published $head to main without force; publishing does not activate the local system" "$DS_STDOUT"
assert_not_contains "$DS_STDERR" "[dotsteward]"
# The fetch, the verification and the pull of the canonical checkout.
assert_eq 3 "$(grep -c 'git-upload-pack' <<<"$(network_calls)")"

# Run again: the remote and the canonical checkout already hold HEAD, so
# nothing is pushed or pulled and nothing is said about the checkout.
reset_logs
assert_exit 0 run_update publish --scope maintain
assert_eq "[dotsteward] main is already $head on the remote; nothing to push" "$DS_STDOUT"
assert_eq "" "$DS_STDERR"
assert_eq 1 "$(grep -c 'git-upload-pack' <<<"$(network_calls)")"
assert_not_contains "$(network_calls)" "git-receive-pack"

# --- warnings ------------------------------------------------------------------------

# Dirty: an untracked file.
candidate
printf 'local\n' >"$canon/local.txt"
published_with_warning "$canon"
rm -f -- "$canon/local.txt"
git -C "$canon" pull -q --ff-only origin main

# Dirty: an untracked file the user's status.showUntrackedFiles = no hides
# from a plain git status.
git config --global status.showUntrackedFiles no
candidate
printf 'local\n' >"$canon/local.txt"
published_with_warning "$canon"
rm -f -- "$canon/local.txt"
git config --global --unset status.showUntrackedFiles
git -C "$canon" pull -q --ff-only origin main

# Dirty: a modified file.
candidate
printf 'edit\n' >>"$canon/docs/guide.md"
published_with_warning "$canon"
git -C "$canon" checkout -q -- docs/guide.md
git -C "$canon" pull -q --ff-only origin main

# On another branch.
candidate
git -C "$canon" checkout -q -b feature
published_with_warning "$canon"
git -C "$canon" checkout -q main
git -C "$canon" branch -q -D feature
git -C "$canon" pull -q --ff-only origin main

# Not at the base: behind it.
candidate
git -C "$canon" reset -q --hard HEAD~1
behind=$(git -C "$canon" rev-parse HEAD)
reset_logs
assert_exit 0 run_update publish --scope maintain
assert_contains "$DS_STDERR" "[dotsteward] WARNING: canonical checkout is not a clean clone of $UP_REMOTE on main at the base OID $base"
assert_eq "$behind" "$(git -C "$canon" rev-parse HEAD)"
git -C "$canon" pull -q --ff-only origin main

# Another origin.
candidate
git -C "$canon" remote set-url origin "$up_bare"
published_with_warning "$canon"
git -C "$canon" remote set-url origin "$UP_REMOTE"
git -C "$canon" pull -q --ff-only origin main

# The fast-forward fails: the canonical checkout cannot store the fetched
# objects.
candidate
chmod -R a-w "$canon/.git/objects"
reset_logs
assert_exit 0 run_update publish --scope maintain
chmod -R u+w "$canon/.git/objects"
assert_eq "$(head_oid)" "$(remote_oid)"
assert_contains "$DS_STDERR" "[dotsteward] WARNING: could not fast-forward the canonical checkout; run 'git pull --ff-only': $canon"
assert_eq "$base" "$(git -C "$canon" rev-parse HEAD)"
git -C "$canon" pull -q --ff-only origin main

# --- skipped silently -------------------------------------------------------------------

# Not a git repository.
mv "$canon" "$DS_TEST_ROOT/canon-saved"
mkdir -p "$canon"
candidate
published_silently
rm -rf -- "$canon"
mv "$DS_TEST_ROOT/canon-saved" "$canon"
git -C "$canon" pull -q --ff-only origin main

# The publishing clone itself (through a symbolic link, compared physically).
set_toml instance checkout "\"$DS_TEST_ROOT/instance-link\""
ln -s "$up_inst" "$DS_TEST_ROOT/instance-link"
candidate
published_silently
assert_eq "$base" "$(git -C "$canon" rev-parse HEAD)" "the default checkout was used"
git -C "$canon" pull -q --ff-only origin main

# --- inventory.json -------------------------------------------------------------------------

set_toml instance checkout "\"$canon\""
commit_all "chore: name the checkout"
git -C "$up_inst" push -q origin main 2>/dev/null
git -C "$canon" pull -q --ff-only origin main
other=$DS_TEST_ROOT/other-canonical
clone_canonical "$other"
mkdir -p "$(dirname "$inventory")"

# canonical_repo wins over instance.checkout.
jq -n --arg repo "$other" '{schema_version: "1.0", canonical_repo: $repo}' >"$inventory"
candidate
reset_logs
assert_exit 0 run_update publish --scope maintain
assert_eq "[dotsteward] canonical checkout fast-forwarded to the published commit: $other" \
  "$(head -n 1 <<<"$DS_STDOUT")"
assert_eq "$(head_oid)" "$(git -C "$other" rev-parse HEAD)"
assert_eq "$base" "$(git -C "$canon" rev-parse HEAD)"
git -C "$canon" pull -q --ff-only origin main

# An inventory path that is not a repository never falls back.
jq -n --arg repo "$DS_TEST_ROOT/missing" '{canonical_repo: $repo}' >"$inventory"
candidate
published_silently
assert_eq "$base" "$(git -C "$canon" rev-parse HEAD)"
git -C "$canon" pull -q --ff-only origin main

# An empty or absent canonical_repo, or an unreadable inventory, falls back
# to instance.checkout.
for document in '{"canonical_repo": ""}' '{"canonical_repo": null}' '{}' 'not json'; do
  printf '%s\n' "$document" >"$inventory"
  candidate
  reset_logs
  assert_exit 0 run_update publish --scope maintain
  assert_eq "[dotsteward] canonical checkout fast-forwarded to the published commit: $canon" \
    "$(head -n 1 <<<"$DS_STDOUT")"
  assert_eq "$(head_oid)" "$(git -C "$canon" rev-parse HEAD)"
done
assert_call_count 0 nix
