# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs and literal texts are single-quoted on purpose
# I2 (SPEC 10.3): a directory that `nix flake init -t` filled (its
# workstation.toml holds the "# dotsteward:template" line) is filled in
# place: the directory itself stays, the result equals init of an empty
# directory with the same options, and the user's own files and edits stay.
# A directory that is a git repository already keeps its history: init adds
# one commit on top of it. `nix flake init` drops the executable bits, so init
# gives the template's executable files (launcher, wrappers, stage 0) their
# modes back.
# shellcheck source=tests/instance/init/helpers.sh
source "$DS_REPO_ROOT/tests/instance/init/helpers.sh"

init_use_nix

# flake_init_copy DIR: the template as `nix flake init -t` leaves it: every
# file writable and none executable.
flake_init_copy() {
  mkdir -p "$1"
  cp -R "$tpl/." "$1/"
  chmod -R u+w "$1"
  find "$1" -type f -exec chmod a-x {} +
}

# template_executables: the executable files of the template, one relative
# path per line.
template_executables() {
  (cd "$tpl" && find . -type f -perm -u+x -printf '%P\n' | LC_ALL=C sort)
}

# assert_executables DIR: the template's executable files are executable in
# DIR and committed with mode 100755.
assert_executables() {
  local relative
  [[ -n $(template_executables) ]] || ds_fail "the template has no executable file"
  while IFS= read -r relative; do
    [[ -x $1/$relative ]] || ds_fail "not executable after init: $relative"
    assert_eq 100755 "$(git -C "$1" ls-files -s -- "$relative" | cut -d' ' -f1)" "the committed mode of $relative"
  done < <(template_executables)
}

# normalized DIR: a copy of DIR without .git and with the generated_at of
# both locks blanked, for comparing two instances.
normalized() {
  local copy
  copy=$(mktemp -d "$DS_TEST_ROOT/normalized.XXXXXX")
  (cd "$1" && tar --exclude=./.git -cf - .) | (cd "$copy" && tar -xf -)
  for lock in versions.lock.json agent/skills.lock.json; do
    sed -i 's/^  "generated_at": .*$/  "generated_at": "",/' "$copy/$lock"
  done
  printf '%s\n' "$copy"
}

# shellcheck disable=SC2054,SC2088 # a comma-separated list and a literal ~/ path are arguments
args=(--remote "$init_remote" --components shell,herdr,opencode-pi --checkout "~/workstation" --non-interactive)

# --- the template, filled in place, is the instance init makes of an empty dir -----

filled=$HOME/a/workstation
flake_init_copy "$filled"
inode=$(stat -c %i "$filled")
init_run 0 --dir "$filled" "${args[@]}"
assert_contains "$DS_STDOUT" "[dotsteward] Initialized the dotsteward instance in $filled"
assert_eq "$inode" "$(stat -c %i "$filled")" "the directory itself stays"
assert_eq "" "$(grep -n 'dotsteward:template' "$filled/workstation.toml" || true)" "the template marker is gone"
assert_eq 1 "$(git -C "$filled" rev-list --count HEAD)" "one commit"
assert_eq "" "$(git -C "$filled" status --porcelain --untracked-files=all)" "clean tree"
assert_executables "$filled"

fresh=$HOME/b/workstation
mkdir -p "$HOME/b"
init_run 0 --dir "$fresh" "${args[@]}"
diff -r "$(normalized "$fresh")" "$(normalized "$filled")" >"$DS_TEST_ROOT/diff" ||
  ds_fail "init of the template dir differs from init of a new dir: $(<"$DS_TEST_ROOT/diff")"
instance_contract "$filled" x86_64-linux

# --- a repository with the template committed, a user file and an edit -------------

repo=$DS_TEST_ROOT/c/workstation
flake_init_copy "$repo"
git -C "$repo" init -q -b main
git -C "$repo" add -A
git -C "$repo" commit -q -m "chore: nix flake init"
first=$(git -C "$repo" rev-parse HEAD)
printf '# Notes about this workstation.\n' >"$repo/NOTES.md"
printf '# My own module.\n' >>"$repo/home.nix"
home_nix=$(<"$repo/home.nix")
init_run 0 --dir "$repo" "${args[@]}"
assert_eq 2 "$(git -C "$repo" rev-list --count HEAD)" "init adds one commit"
assert_eq "$first" "$(git -C "$repo" rev-parse HEAD~1)" "the history stays"
assert_eq "chore: initialize dotsteward instance" "$(git -C "$repo" log -1 --format=%s)" "commit subject"
assert_eq "# Notes about this workstation." "$(<"$repo/NOTES.md")" "the user's file stays"
assert_eq "$home_nix" "$(<"$repo/home.nix")" "the user's edit stays"
assert_executables "$repo"
assert_eq "" "$(git -C "$repo" status --porcelain --untracked-files=all)" "clean tree"
git -C "$repo" ls-files --error-unmatch NOTES.md flake.lock .dotsteward/manifest.x86_64-linux.json >/dev/null ||
  ds_fail "the new files are not committed"
# Nix saw the files of the staged repository (git add before the lock).
assert_eq "# Notes about this workstation." "$(<"$(init_staged)/NOTES.md")" "the staged copy holds the user's file"

# --- a repository without a commit -----------------------------------------------------

bare=$DS_TEST_ROOT/d/workstation
flake_init_copy "$bare"
git -C "$bare" init -q -b main
init_run 0 --dir "$bare" "${args[@]}"
assert_eq 1 "$(git -C "$bare" rev-list --count HEAD)" "one commit"
assert_eq main "$(git -C "$bare" symbolic-ref --short HEAD)" "branch"
assert_eq "" "$(git -C "$bare" status --porcelain --untracked-files=all)" "clean tree"
assert_eq "" "$(init_temp_dirs)" "no temporary directory is left"
