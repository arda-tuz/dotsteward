# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs and literal texts are single-quoted on purpose
# I3 (SPEC 10.3): what init refuses before any write and any Nix call. A
# directory that is neither missing, empty nor a template is refused with
# exit 1 (so are a file, a missing parent, an unsafe identity and a missing
# git identity); usage errors exit 2. Every refusal leaves the target as it
# was, calls no nix and leaves no temporary directory.
# shellcheck source=tests/instance/init/helpers.sh
source "$DS_REPO_ROOT/tests/instance/init/helpers.sh"

init_use_nix

# refused STATUS NEEDLE [ENV=VALUE...] -- ARG...: init with ARG exits with
# STATUS, its standard error holds NEEDLE, no nix call happened and no
# temporary directory is left.
refused() {
  local status=$1 needle=$2 environment=()
  shift 2
  while (($#)) && [[ $1 != -- ]]; do
    environment+=("$1")
    shift
  done
  [[ ${1:-} == -- ]] || ds_fail "refused: usage: refused STATUS NEEDLE [ENV=VALUE...] -- ARG..."
  shift
  : >"$DS_CALL_LOG"
  assert_exit "$status" env "${environment[@]}" "$DS_CLI" init "$@"
  assert_contains "$DS_STDERR" "$needle"
  assert_eq "" "$DS_STDOUT" "no output on standard output"
  assert_call_count 0 nix
  assert_eq "" "$(init_temp_dirs)" "no temporary directory is left"
}

dir=$DS_TEST_ROOT/instances/workstation
mkdir -p "$DS_TEST_ROOT/instances"
ok=(--dir "$dir" --remote "$init_remote")

# --- the target ----------------------------------------------------------------------

# A directory with foreign files.
mkdir -p "$dir"
printf '# A project\n' >"$dir/README.md"
before=$(tree_state "$dir")
refused 1 "[dotsteward] ERROR: $dir is not empty and is not a dotsteward template (no \"# dotsteward:template\" line in its workstation.toml)" -- "${ok[@]}"
assert_unchanged "$dir" "$before"

# Hidden files count: a directory with only .git is not empty.
rm -rf "$dir"
mkdir -p "$dir"
git -C "$dir" init -q
before=$(tree_state "$dir")
refused 1 "is not empty and is not a dotsteward template" -- "${ok[@]}"
assert_unchanged "$dir" "$before"

# An instance init already made (no marker any more).
rm -rf "$dir"
mkdir -p "$dir"
cp -R "$tpl/." "$dir/"
sed -i '/^# dotsteward:template$/d' "$dir/workstation.toml"
before=$(tree_state "$dir")
refused 1 "is not empty and is not a dotsteward template" -- "${ok[@]}"
assert_unchanged "$dir" "$before"
rm -rf "$dir"

# A file, a dangling symbolic link and a missing parent.
printf 'x\n' >"$dir"
refused 1 "[dotsteward] ERROR: --dir is not a directory: $dir" -- "${ok[@]}"
assert_eq x "$(<"$dir")" "the file is untouched"
rm -f "$dir"
ln -s "$DS_TEST_ROOT/nowhere" "$dir"
refused 1 "[dotsteward] ERROR: --dir is not a directory: $dir" -- "${ok[@]}"
assert_symlink_to "$dir" "$DS_TEST_ROOT/nowhere"
rm -f "$dir"
refused 1 "[dotsteward] ERROR: the parent directory of --dir does not exist: $DS_TEST_ROOT/missing" -- \
  --dir "$DS_TEST_ROOT/missing/workstation" --remote "$init_remote"
[[ ! -e $DS_TEST_ROOT/missing ]] || ds_fail "the missing parent was created"

# A template directory whose repository lives elsewhere: git calls in the
# temporary copy would reach the other repository's git directory (its
# index, objects and refs) or its work tree, so init refuses before it
# copies anything. A linked worktree (its .git is a file naming the main
# repository's git directory), a .git symbolic link and a .git directory
# whose core.worktree names another directory.
main=$DS_TEST_ROOT/main
mkdir -p "$main"
printf 'main\n' >"$main/README"
git -C "$main" init -q -b main
commit_all "$main" "chore: the main repository"
git -C "$main" worktree add -q -b station "$dir"
cp -R "$tpl/." "$dir/"
chmod -R u+w "$dir"
commit_all "$dir" "chore: nix flake init"
printf '# edited\n' >>"$dir/workstation.toml"
index=$(sha256sum <"$main/.git/worktrees/workstation/index")
status=$(git -C "$dir" status --porcelain)
main_head=$(git -C "$main" rev-parse HEAD)
before=$(tree_state "$dir")
refused 1 "[dotsteward] ERROR: $dir is a linked git worktree or a submodule (its .git is a file that points at another repository's git directory); run init in a standalone repository or a new directory" -- "${ok[@]}"
assert_unchanged "$dir" "$before" "the linked worktree"
assert_eq "$index" "$(sha256sum <"$main/.git/worktrees/workstation/index")" "the linked worktree's index"
assert_eq "$status" "$(git -C "$dir" status --porcelain)" "the linked worktree's status"
assert_eq "$main_head" "$(git -C "$main" rev-parse HEAD)" "the main repository's HEAD"
git -C "$main" worktree remove --force "$dir"

mkdir -p "$dir"
cp -R "$tpl/." "$dir/"
git init -q -b main --separate-git-dir "$DS_TEST_ROOT/separate.git" "$dir"
rm "$dir/.git"
ln -s "$DS_TEST_ROOT/separate.git" "$dir/.git"
commit_all "$dir" "chore: nix flake init"
separate_index=$(sha256sum <"$DS_TEST_ROOT/separate.git/index")
before=$(tree_state "$dir")
refused 1 "[dotsteward] ERROR: $dir/.git is a symbolic link to another directory; run init in a standalone repository or a new directory" -- "${ok[@]}"
assert_unchanged "$dir" "$before" "the .git symbolic link"
assert_eq "$separate_index" "$(sha256sum <"$DS_TEST_ROOT/separate.git/index")" "the linked git directory's index"
rm -rf "$dir"

mkdir -p "$dir" "$DS_TEST_ROOT/elsewhere"
cp -R "$tpl/." "$dir/"
git -C "$dir" init -q -b main
git -C "$dir" config core.worktree "$DS_TEST_ROOT/elsewhere"
before=$(tree_state "$dir")
refused 1 "[dotsteward] ERROR: $dir/.git/config sets core.worktree ($DS_TEST_ROOT/elsewhere), so git works on another directory; run init in a standalone repository or a new directory" -- "${ok[@]}"
assert_unchanged "$dir" "$before" "the repository with core.worktree"
assert_eq "" "$(ls -A "$DS_TEST_ROOT/elsewhere")" "the other work tree stays empty"
rm -rf "$dir"

# --- the identity ---------------------------------------------------------------------

refused 1 "unsafe user name" USER='Bad User' -- "${ok[@]}"
refused 1 "unsafe user name" -- "${ok[@]}" --username 'bad$user'
refused 1 "unsafe HOME" HOME=relative/home -- "${ok[@]}"
refused 1 "unsafe HOME" -- "${ok[@]}" --home "$DS_TEST_ROOT/no such home"
refused 1 "unsafe HOME" -- "${ok[@]}" --home "$DS_TEST_ROOT/absent"
[[ ! -e $dir ]] || ds_fail "a refusal created $dir"

# No git identity for the commit (the check comes before any write; --no-git
# needs none, see test-options.sh).
printf '[init]\ndefaultBranch = main\n' >"$DS_TEST_ROOT/gitconfig-anonymous"
refused 1 "[dotsteward] ERROR: git has no identity for the commit; set user.name and user.email (git config --global), or pass --no-git" \
  GIT_CONFIG_GLOBAL="$DS_TEST_ROOT/gitconfig-anonymous" EMAIL=someone@example.invalid -- "${ok[@]}"
[[ ! -e $dir ]] || ds_fail "a refusal created $dir"

# --- usage errors -----------------------------------------------------------------------

usage="Usage: dotsteward init --dir DIR --remote URL [OPTION]..."
refused 2 "$usage" --
refused 2 "the following arguments are required: --remote" -- --dir "$dir"
refused 2 "the following arguments are required: --dir" -- --remote "$init_remote"
refused 2 "unrecognized arguments: --bogus" -- "${ok[@]}" --bogus
refused 2 "unrecognized arguments: extra" -- "${ok[@]}" extra
refused 2 "--remote must be non-empty, without whitespace, quotes, backslashes or \$" -- --dir "$dir" --remote ""
refused 2 "--remote must be non-empty" -- --dir "$dir" --remote "git@example.invalid:a b.git"
refused 2 "unknown component: editor (the catalog: shell, herdr, claude-code, codex, opencode-pi, vscode)" -- \
  "${ok[@]}" --components shell,editor
refused 2 "--components: shell given more than once" -- "${ok[@]}" --components shell,herdr,shell
refused 2 "--method expects COMPONENT=VALUE, got 'codex'" -- "${ok[@]}" --components codex --method codex
refused 2 "--method codex=deb: codex is not among the chosen components" -- "${ok[@]}" --components shell --method codex=deb
refused 2 "--method: codex given more than once" -- "${ok[@]}" --components codex \
  --method codex=external --method codex=official-binary
refused 2 "components.codex.method" -- "${ok[@]}" --components codex --method codex=bogus
refused 2 "--method-platform vscode=windows:deb: expected PLATFORM:METHOD pairs, PLATFORM linux or darwin" -- \
  "${ok[@]}" --components vscode --method-platform vscode=windows:deb
refused 2 "--method-platform vscode=linux:deb,linux:deb: linux given more than once" -- \
  "${ok[@]}" --components vscode --method-platform vscode=linux:deb,linux:deb
refused 2 "--systems: unsupported system x86_64-darwin (supported: x86_64-linux, aarch64-darwin)" -- \
  "${ok[@]}" --systems x86_64-linux,x86_64-darwin
refused 2 "--systems: at least one system is required" -- "${ok[@]}" --systems ,
refused 2 "--profiles expects two different names ADOPT_NAME,FRESH_NAME, got 'only'" -- "${ok[@]}" --profiles only
refused 2 "--profiles expects two different names" -- "${ok[@]}" --profiles same,same
refused 2 "--profiles: names is a key of [profiles], not a profile name" -- "${ok[@]}" --profiles names,fresh
refused 2 "profiles.names" -- "${ok[@]}" --profiles 'dev,new box'
refused 2 "argument --contribute: invalid choice: 'upstream'" -- "${ok[@]}" --contribute upstream
refused 2 "argument --framework-url: not allowed with argument --framework-ref" -- \
  "${ok[@]}" --framework-ref v1.2.3 --framework-url path:/somewhere
refused 2 "--framework-ref expects a release tag vX.Y.Z, got 'main'" -- "${ok[@]}" --framework-ref main
refused 2 "--framework-url must be non-empty" -- "${ok[@]}" --framework-url 'path:/a"b'
refused 2 "instance.name" -- "${ok[@]}" --name 'my box'
[[ ! -e $dir ]] || ds_fail "a usage error created $dir"

# --- help ---------------------------------------------------------------------------------

assert_exit 0 "$DS_CLI" init --help
assert_contains "$DS_STDOUT" "usage: dotsteward init --dir DIR --remote URL [OPTION]..."
for option in --dir --remote --username --home --name --checkout --components --method --method-platform \
  --systems --profiles --allow-unfree --contribute --framework-ref --framework-url --no-git --non-interactive --json; do
  assert_contains "$DS_STDOUT" "$option" "init --help lists $option"
done
assert_exit 0 "$DS_CLI" --help
assert_contains "$DS_STDOUT" "init  "
assert_contains "$DS_STDOUT" "Create a new instance from the framework template"
