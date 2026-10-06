# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# backup_file_private SRC ROOT (copy below ROOT/files/<absolute path>,
# regular files 0600, links and directories as they are) and
# backup_copy_of TARGET (the newest backup with a regular-file copy; the
# legacy files/home/<rel> layout only with compat.legacy_backup_layout).
# shellcheck source=tests/cli/lib/helpers.sh
source "$DS_REPO_ROOT/tests/cli/lib/helpers.sh"

root=$DS_TEST_ROOT/backup-root

# A regular file: same bytes, mode 0600.
mkdir -p "$HOME/.config/app"
printf 'secret=1\n' >"$HOME/.config/app/config.toml"
chmod 0644 "$HOME/.config/app/config.toml"
backup_file_private "$HOME/.config/app/config.toml" "$root"
copy=$root/files$HOME/.config/app/config.toml
cmp "$HOME/.config/app/config.toml" "$copy"
assert_file_mode "$copy" 600

# A directory tree keeps its modes; a symlink stays a link; a dangling link
# is copied as a link.
mkdir -p "$HOME/tree/sub"
printf 'x' >"$HOME/tree/sub/file"
chmod 0750 "$HOME/tree/sub"
chmod 0640 "$HOME/tree/sub/file"
backup_file_private "$HOME/tree" "$root"
assert_file_mode "$root/files$HOME/tree/sub" 750
assert_file_mode "$root/files$HOME/tree/sub/file" 640
ln -s .config/app/config.toml "$HOME/link"
backup_file_private "$HOME/link" "$root"
assert_symlink_to "$root/files$HOME/link" .config/app/config.toml
ln -s "$HOME/missing-target" "$HOME/dangling"
backup_file_private "$HOME/dangling" "$root"
assert_symlink_to "$root/files$HOME/dangling" "$HOME/missing-target"

# A missing source is a no-op; a relative source is refused.
backup_file_private "$HOME/does-not-exist" "$root"
[[ ! -e $root/files$HOME/does-not-exist ]] || ds_fail "missing source copied"
relative_backup() {
  cd "$HOME" && backup_file_private .config/app/config.toml "$root"
}
assert_exit 1 relative_backup
assert_eq "[dotsteward] ERROR: backup source must be an absolute path: .config/app/config.toml" "$DS_STDERR"

# backup_copy_of: the layouts of ds_fixture_backup_layouts.
ds_fixture_backup_layouts "$DOTSTEWARD_STATE_ROOT"
backups=$DOTSTEWARD_STATE_ROOT/backups
assert_eq "$backups/20260102T000000Z-adopt/files$HOME/.zshrc" "$(backup_copy_of "$HOME/.zshrc")" "newest wins"
assert_eq "$backups/20260103T000000Z-skills/files$HOME/.agents/skills/example-skill/SKILL.md" \
  "$(backup_copy_of "$HOME/.agents/skills/example-skill/SKILL.md")"
# Only regular files count: the dangling link copy is not a backup.
assert_exit 1 backup_copy_of "$HOME/.config/link"
assert_eq "" "$DS_STDOUT"
# Directories without a files/ level are not backups of this layout.
assert_exit 1 backup_copy_of "$HOME/.config/example-term/config.toml"
# The legacy files/home/<rel> layout counts only with the compat flag.
assert_exit 1 backup_copy_of "$HOME/.codex/AGENTS.md"
legacy() { DS_COMPAT_LEGACY_BACKUP_LAYOUT=$1 backup_copy_of "$2"; }
assert_exit 1 legacy false "$HOME/.codex/AGENTS.md"
assert_exit 0 legacy true "$HOME/.codex/AGENTS.md"
assert_eq "$backups/20251231T000000Z/files/home/.codex/AGENTS.md" "$DS_STDOUT"
# With the flag, a newer current-layout copy still wins over an older legacy
# one, and within one directory the current layout is tried first.
mkdir -p "$backups/20260106T000000Z/files/home/.zshrc-dir"
mkdir -p "$backups/20260107T000000Z/files$HOME" "$backups/20260107T000000Z/files/home"
printf 'current\n' >"$backups/20260107T000000Z/files$HOME/.bashrc"
printf 'legacy\n' >"$backups/20260107T000000Z/files/home/.bashrc"
assert_exit 0 legacy true "$HOME/.bashrc"
assert_eq "$backups/20260107T000000Z/files$HOME/.bashrc" "$DS_STDOUT"
assert_exit 0 legacy true "$HOME/.zshrc"
assert_eq "$backups/20260102T000000Z-adopt/files$HOME/.zshrc" "$DS_STDOUT"
# Paths outside HOME have no legacy candidate.
mkdir -p "$backups/20260108T000000Z/files/home/etc"
printf 'x\n' >"$backups/20260108T000000Z/files/home/etc/shells"
assert_exit 1 legacy true /etc/shells
# A relative target is refused; a missing backups directory returns 1.
assert_exit 1 backup_copy_of relative/path
assert_eq "[dotsteward] ERROR: backup lookup needs an absolute path: relative/path" "$DS_STDERR"
missing_root() { DOTSTEWARD_STATE_ROOT=$DS_TEST_ROOT/no-state backup_copy_of "$HOME/.zshrc"; }
assert_exit 1 missing_root
assert_eq "" "$DS_STDERR"
# Without DOTSTEWARD_STATE_ROOT the framework default state root is used.
xdg_default() {
  unset DOTSTEWARD_STATE_ROOT
  XDG_STATE_HOME=$DS_TEST_ROOT/xdg backup_copy_of "$HOME/.zshrc"
}
mkdir -p "$DS_TEST_ROOT/xdg/dotsteward/backups/20260101T000000Z/files$HOME"
printf 'x\n' >"$DS_TEST_ROOT/xdg/dotsteward/backups/20260101T000000Z/files$HOME/.zshrc"
assert_exit 0 xdg_default
assert_eq "$DS_TEST_ROOT/xdg/dotsteward/backups/20260101T000000Z/files$HOME/.zshrc" "$DS_STDOUT"
assert_eq "$DS_TEST_ROOT/state" "$(state_root)"
assert_eq "$HOME/.local/state/dotsteward" "$(unset DOTSTEWARD_STATE_ROOT XDG_STATE_HOME; state_root)"
