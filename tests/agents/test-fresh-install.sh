# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Copy deployment on a fresh home: the native copy installs each locked skill as
# a physical directory <canonical>/<directory> (modes = source modes & 0777;
# metadata.json, .git, __pycache__ and __pypackages__ left out; file symlinks
# dereferenced), the Claude link ~/.claude/skills/<name> ->
# ../../.agents/skills/<directory> follows, check passes and a second install
# changes nothing and prints only the final line. A copy whose digest cannot
# equal the lock (the source holds a symlinked file) is reported right after the
# install.
# shellcheck source=tests/agents/helpers.sh
source "$DS_REPO_ROOT/tests/agents/helpers.sh"

lock_add alpha
lock_add beta --no-directory-digest
beta_src=$(vendored beta)
mkdir -p "$beta_src/.git" "$beta_src/__pycache__" "$beta_src/__pypackages__" "$beta_src/nested/__pycache__"
printf 'ref\n' >"$beta_src/.git/HEAD"
printf 'bytecode' >"$beta_src/__pycache__/x.pyc"
printf 'bytecode' >"$beta_src/nested/__pycache__/y.pyc"
printf 'pkg\n' >"$beta_src/__pypackages__/pkg.txt"
printf '{}\n' >"$beta_src/metadata.json"
printf 'kept\n' >"$beta_src/nested/kept.txt"
chmod 0640 "$beta_src/nested/kept.txt"

# Check on the fresh home: the layout is missing.
before=$(home_state)
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "skill root missing: $HOME/.codex/skills"
mkdir -p "$HOME/.codex/skills"
assert_exit 1 run_agents check
assert_contains "$DS_STDERR" "canonical skill directory missing: $HOME/.agents/skills"
rmdir "$HOME/.codex/skills" "$HOME/.codex"
assert_eq "$before" "$(home_state)" "check writes nothing"

assert_exit 0 run_agents install
assert_contains "$DS_STDOUT" "installed skill alpha into $HOME/.agents/skills/alpha"
assert_contains "$DS_STDOUT" "installed skill beta into $HOME/.agents/skills/beta"
alpha=$HOME/.agents/skills/alpha
[[ -d $alpha && ! -L $alpha ]] || ds_fail "alpha is a physical copy"
assert_eq "$(cat "$alpha/SKILL.md")" "$(cat "$(vendored alpha)/SKILL.md")"
assert_file_mode "$alpha/scripts/run.sh" 0755
assert_file_mode "$alpha/notes/private.txt" 0600
assert_file_mode "$alpha/notes" 0750
assert_file_mode "$alpha/SKILL.md" 0644
assert_symlink_to "$HOME/.claude/skills/alpha" ../../.agents/skills/alpha
assert_symlink_to "$HOME/.claude/skills/beta" ../../.agents/skills/beta
beta=$HOME/.agents/skills/beta
for excluded in .git __pycache__ __pypackages__ metadata.json nested/__pycache__; do
  [[ ! -e $beta/$excluded ]] || ds_fail "the copy leaves out $excluded"
done
assert_eq "$(cat "$beta/nested/kept.txt")" kept
assert_file_mode "$beta/nested/kept.txt" 0640
[[ -z $(find "$HOME/.agents/skills" -type l) ]] || ds_fail "the copies contain no symlinks"

assert_exit 0 run_agents check
assert_eq "$DS_STDOUT" "[dotsteward] agent tools and skills verified (profile workstation)"
assert_eq "$DS_STDERR" ""

# A second install is a no-op.
before=$(home_state)
assert_exit 0 run_agents install
assert_eq "$DS_STDOUT" "[dotsteward] agent tools and skills installed (profile workstation)"
assert_eq "$DS_STDERR" ""
assert_eq "$before" "$(home_state)" "the second install changes nothing"

# A skill whose source holds a symlinked file: the dereferencing copy cannot
# match the directory digest, which ignores symlinks.
lock_add gamma --tree
assert_exit 1 run_agents install
assert_contains "$DS_STDERR" "installed skill digest differs from the lock: gamma ($HOME/.agents/skills/gamma)"
[[ ! -L $HOME/.agents/skills/gamma/link.md && -f $HOME/.agents/skills/gamma/link.md ]] ||
  ds_fail "file symlinks are dereferenced"
assert_eq "$(temp_dirs)" "" "no temporary directory is left behind"
