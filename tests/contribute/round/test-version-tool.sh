# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# tools/version.sh: VERSION is the only hand-written copy of the framework
# version. sync writes the others (every "version" key of the plugin and
# marketplace manifests, the release tag of the dotsteward input of
# template/flake.nix) and --check finds a stale one; no other file of the
# tree carries the version. next computes the next release from the
# conventional commits since the newest release the commit contains (any
# feat: minor, otherwise patch; a breaking change only with --major, else
# exit 3; nothing new: exit 2), after the newest release tag of the clone;
# notes groups the subjects (Features, Fixes, Other); bump writes the next
# version into VERSION and its copies.

tool=$DS_REPO_ROOT/tools/version.sh
[[ -x $tool ]] || ds_fail "tools/version.sh is missing or not executable"
copies=(.claude-plugin/marketplace.json .agents/plugins/marketplace.json
  plugins/dotsteward/.claude-plugin/plugin.json plugins/dotsteward/.codex-plugin/plugin.json template/flake.nix)
version=$(<"$DS_REPO_ROOT/VERSION")

# --- the framework tree ------------------------------------------------------------------------

assert_exit 0 "$tool" sync --check --root "$DS_REPO_ROOT"
# Every file that carries the version is VERSION or one of its copies (the
# tests and the lock files hold versions of other things; a file that
# carries an equal version of something else by coincidence belongs in
# these exclusions).
if git -C "$DS_REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  carriers=$(git -C "$DS_REPO_ROOT" grep -lF -e "$version" -- . ':!tests' ':!*.lock' ':!*.lock.json' || true)
else
  carriers=$(cd "$DS_REPO_ROOT" && grep -rlF --exclude-dir=tests --exclude='*.lock' --exclude='*.lock.json' \
    -e "$version" . | sed 's|^\./||' || true)
fi
assert_eq "$(printf '%s\n' VERSION .claude-plugin/marketplace.json plugins/dotsteward/.claude-plugin/plugin.json \
  plugins/dotsteward/.codex-plugin/plugin.json template/flake.nix | LC_ALL=C sort)" \
  "$(LC_ALL=C sort <<<"$carriers")" "the files that carry VERSION $version"

# --- sync on a copy -------------------------------------------------------------------------------

root=$DS_TEST_ROOT/fw
for file in VERSION "${copies[@]}"; do
  mkdir -p "$(dirname "$root/$file")"
  cp -- "$DS_REPO_ROOT/$file" "$root/$file"
done
printf '9.8.7\n' >"$root/VERSION"
assert_exit 1 "$tool" sync --check --root "$root"
for file in .claude-plugin/marketplace.json plugins/dotsteward/.claude-plugin/plugin.json \
  plugins/dotsteward/.codex-plugin/plugin.json template/flake.nix; do
  assert_contains "$DS_STDERR" "[version] stale: $file does not carry VERSION 9.8.7"
done
assert_not_contains "$DS_STDERR" ".agents/plugins/marketplace.json"
assert_contains "$DS_STDERR" "[version] ERROR: run tools/version.sh sync"
assert_eq "$version" "$(jq -r .version "$root/plugins/dotsteward/.claude-plugin/plugin.json")" "--check writes nothing"

assert_exit 0 "$tool" sync --root "$root"
assert_contains "$DS_STDOUT" "[version] wrote template/flake.nix (9.8.7)"
assert_exit 0 "$tool" sync --check --root "$root"
for file in "${copies[@]}"; do
  assert_eq "$(sed "s/$version/9.8.7/g" "$DS_REPO_ROOT/$file")" "$(cat "$root/$file")" "$file after sync"
  [[ $file == .agents/* ]] || assert_file_mode "$root/$file" 644
done
assert_exit 0 "$tool" sync --root "$root"
assert_eq "" "$DS_STDOUT" "a second sync writes nothing"

# A template without its one release tag is refused, not guessed.
sed -i 's|github:\([^/]*\)/dotsteward/v9.8.7|git+file:///srv/dotsteward|' "$root/template/flake.nix"
assert_exit 1 "$tool" sync --root "$root"
assert_contains "$DS_STDERR" "[version] ERROR: template/flake.nix needs exactly one url = \"github:OWNER/dotsteward/vX.Y.Z\" line, found 0"

# --- next, notes and bump in a framework history --------------------------------------------------

repo=$DS_TEST_ROOT/history
mkdir -p "$repo"
for file in "${copies[@]}"; do
  mkdir -p "$(dirname "$repo/$file")"
  cp -- "$DS_REPO_ROOT/$file" "$repo/$file"
done
printf '1.4.2\n' >"$repo/VERSION"
git -C "$repo" init -q -b main
"$tool" sync --root "$repo" >/dev/null
git -C "$repo" add -A
git -C "$repo" commit -q -m "chore(release): 1.4.2"
git -C "$repo" tag -a v1.4.2 -m "dotsteward v1.4.2"
# A tag that is not a stable release does not count.
git -C "$repo" tag v1.9.0-rc.1

change() {
  printf '%s\n' "$1" >>"$repo/changes.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$1" ${2:+-m "$2"}
}
short() {
  git -C "$repo" log -1 --format=%h "${1:-HEAD}"
}

assert_exit 2 "$tool" next --root "$repo"
assert_contains "$DS_STDERR" "[version] nothing to release: HEAD has no commit after v1.4.2"

change "docs: explain the widget"
assert_exit 0 "$tool" next --root "$repo"
assert_eq 1.4.3 "$DS_STDOUT" "any change is a patch"
change "fix(cli): read the right file"
assert_exit 0 "$tool" next --root "$repo"
assert_eq 1.4.3 "$DS_STDOUT" "a fix is a patch"
fix=$(short)
change "feat(cli): add the widget"
feature=$(short)
assert_exit 0 "$tool" next --root "$repo"
assert_eq 1.5.0 "$DS_STDOUT" "a feat is a minor"
# An older commit counts only what it contains.
assert_exit 0 "$tool" next --root "$repo" "$fix"
assert_eq 1.4.3 "$DS_STDOUT" "next of an older commit"

# A merge brings no subject of its own.
git -C "$repo" checkout -q -b side
change "test(cli): cover the widget"
tested=$(short)
git -C "$repo" checkout -q main
git -C "$repo" merge -q --no-ff -m "Merge branch side" side
assert_exit 0 "$tool" notes --root "$repo"
assert_eq "## Features

- cli: add the widget ($feature)

## Fixes

- cli: read the right file ($fix)

## Other

- explain the widget ($(short "$fix^"))
- cli: cover the widget ($tested)" "$DS_STDOUT" "grouped notes"

# bump: VERSION and its copies; --commit makes the release commit of
# exactly those files, with UTC dates, and leaves other changes out.
assert_exit 0 "$tool" bump --root "$repo"
assert_contains "$DS_STDOUT" "[version] VERSION: 1.4.2 -> 1.5.0"
assert_eq 1.5.0 "$(<"$repo/VERSION")" "VERSION after bump"
assert_exit 0 "$tool" sync --check --root "$repo"
assert_contains "$(cat "$repo/template/flake.nix")" "/dotsteward/v1.5.0\";"
git -C "$repo" checkout -q -- .
printf 'unrelated\n' >>"$repo/changes.txt"
before=$(git -C "$repo" rev-parse HEAD)
assert_exit 0 env TZ=Europe/Berlin "$tool" bump --commit --root "$repo"
assert_contains "$DS_STDOUT" "[version] committed: chore(release): 1.5.0 ($(git -C "$repo" rev-parse --short=12 HEAD))"
assert_eq "$before" "$(git -C "$repo" rev-parse HEAD^)" "one release commit"
assert_eq "chore(release): 1.5.0" "$(git -C "$repo" log -1 --format=%s)" "release commit subject"
assert_eq "$(printf '%s\n' VERSION "${copies[@]}" | grep -vxF .agents/plugins/marketplace.json | LC_ALL=C sort)" \
  "$(git -C "$repo" diff --name-only HEAD^ HEAD | LC_ALL=C sort)" "files of the release commit"
assert_eq "+0000 +0000" "$(git -C "$repo" log -1 --format='%ad %cd' --date=format:%z)" "UTC dates of the release commit"
assert_eq " M changes.txt" "$(git -C "$repo" status --porcelain)" "other changes stay out of the release commit"
git -C "$repo" checkout -q -- changes.txt
git -C "$repo" tag -a v1.5.0 -m "dotsteward v1.5.0"

# A breaking change: the next major only with --major, a decision of the
# user; the subject form and the footer form both count.
change "fix(cli)!: drop the old flag"
assert_exit 3 "$tool" next --root "$repo"
assert_contains "$DS_STDERR" "[version] ERROR: the commits since v1.5.0 hold a breaking change: the next release is a major one, which needs --major (a decision of the user)"
assert_exit 3 "$tool" bump --root "$repo"
assert_eq 1.5.0 "$(<"$repo/VERSION")" "VERSION after a refused bump"
assert_exit 0 "$tool" next --major --root "$repo"
assert_eq 2.0.0 "$DS_STDOUT" "the next major"
git -C "$repo" reset -q --hard v1.5.0
change "refactor(cli): rename the store" "BREAKING CHANGE: the store moved."
assert_exit 3 "$tool" next --root "$repo"
assert_exit 0 "$tool" notes --root "$repo"
assert_eq "## Other

- Breaking: cli: rename the store ($(short))" "$DS_STDOUT" "a breaking footer in the notes"

# The next release follows the newest release tag even when this history
# does not contain it (the release of a fork, for example).
git -C "$repo" reset -q --hard v1.5.0
git -C "$repo" checkout -q -b elsewhere
change "fix(cli): a fix elsewhere"
git -C "$repo" tag v1.7.0
git -C "$repo" checkout -q main
change "fix(cli): a fix here"
assert_exit 0 "$tool" next --root "$repo"
assert_eq 1.7.1 "$DS_STDOUT" "next after the newest tag of the clone"
assert_exit 0 "$tool" notes --root "$repo"
assert_eq "## Fixes

- cli: a fix here ($(short))" "$DS_STDOUT" "notes since the release this history contains"

# Usage.
assert_exit 1 "$tool" frobnicate
assert_contains "$DS_STDERR" "[version] ERROR: unknown command: frobnicate"
assert_exit 0 "$tool" --help
assert_contains "$DS_STDOUT" "tools/version.sh release --repo OWNER/REPO"
