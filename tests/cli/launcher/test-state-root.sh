# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The launcher's own state root resolution (spec 6.3): DOTSTEWARD_STATE_ROOT
# > DOTFILES_STATE_ROOT when [compat] legacy_env = true > state.root from
# workstation.toml > ${XDG_STATE_HOME:-~/.local/state}/dotsteward. state.root
# expands like the CLI's own resolver: a leading ${NAME:-DEFAULT} (NAME when
# set and non-empty), then a leading ~. The cache entry $STATE/cli/<key>
# shows which root was used.
# shellcheck source=tests/cli/launcher/helpers.sh
source "$DS_REPO_ROOT/tests/cli/launcher/helpers.sh"

launcher_use_stub_nix
unset DOTSTEWARD_STATE_ROOT XDG_STATE_HOME DOTFILES_STATE_ROOT XDG_DATA_HOME DS_LAUNCHER_BASE

count=0
# instance_with TOML_EXTRA: a fresh instance whose workstation.toml ends
# with TOML_EXTRA; sets inst and key.
instance_with() {
  count=$((count + 1))
  inst=$DS_TEST_ROOT/instance-$count
  launcher_instance "$inst" <<<"$1"
  key=$(launcher_key "$inst")
}

# expect_root ROOT [ENV...]: running the launcher with ENV caches under
# ROOT and nowhere else.
expect_root() {
  local root=$1
  shift
  rm -rf -- "$DS_TEST_ROOT/roots"
  assert_exit 0 env "$@" "$inst/.dotsteward/cli.sh" version
  [[ -L $root/cli/$key && -x $root/cli/$key/bin/dotsteward ]] ||
    ds_fail "expected the cache entry under [$root]; stderr [$DS_STDERR]"
  rm -rf -- "$root/cli"
}

r=$DS_TEST_ROOT/roots

# Default: ~/.local/state/dotsteward, or under XDG_STATE_HOME.
instance_with ""
expect_root "$HOME/.local/state/dotsteward"
expect_root "$r/xdg/dotsteward" XDG_STATE_HOME="$r/xdg"
# A relative XDG_STATE_HOME is invalid per the XDG specification: ignored.
expect_root "$HOME/.local/state/dotsteward" XDG_STATE_HOME=relative/xdg

# state.root in a [state] table, with ~/ expansion and comments.
instance_with $'[state]\nroot = "~/custom-state"'
expect_root "$HOME/custom-state"
instance_with "$(printf '[ state ]   # machine records\n  root   =   "%s"  # a comment' "$r/spaced")"
expect_root "$r/spaced"
instance_with $'[state]\nroot = \'~/literal-state\''
expect_root "$HOME/literal-state"
instance_with $'[state]\nroot = "~"'
expect_root "$HOME"

# Dotted key at the top level (before the first table).
instance_with ""
cat >"$inst/workstation.toml" <<EOF
schema_version = 1
state.root = "$r/dotted"

[identity]
username = "dotsteward-test"
EOF
expect_root "$r/dotted"

# The schema default spelled out expands like the default.
instance_with $'[state]\nroot = "${XDG_STATE_HOME:-~/.local/state}/dotsteward"'
expect_root "$HOME/.local/state/dotsteward"
expect_root "$r/xdg2/dotsteward" XDG_STATE_HOME="$r/xdg2"

# Any leading ${NAME:-DEFAULT} expands, as in the CLI: NAME when set and
# non-empty, else DEFAULT, then a leading ~ in the result.
instance_with $'[state]\nroot = "${XDG_DATA_HOME:-~/.local/share}/data-state"'
expect_root "$HOME/.local/share/data-state"
expect_root "$r/data/data-state" XDG_DATA_HOME="$r/data"
expect_root "$HOME/.local/share/data-state" XDG_DATA_HOME=
instance_with "[state]"$'\n'"root = \"\${DS_LAUNCHER_BASE:-$r/absolute-default}/x\""
expect_root "$r/absolute-default/x"
expect_root "$r/base/x" DS_LAUNCHER_BASE="$r/base"
expect_root "$HOME/home-base/x" DS_LAUNCHER_BASE="~/home-base"
instance_with $'[state]\nroot = "${DS_LAUNCHER_BASE:-~}"'
expect_root "$HOME"
instance_with $'[state]\nroot = "${DS_LAUNCHER_BASE:-~/plain}"'
expect_root "$HOME/plain"

# Only a leading expansion is expanded; the result must be absolute, and the
# refusal names the expanded path, before any Nix call.
instance_with $'[state]\nroot = "${XDG_STATE_HOME:-~/.local/state}/dotsteward"'
: >"$DS_CALL_LOG"
assert_exit 1 env XDG_STATE_HOME=relative/xdg "$inst/.dotsteward/cli.sh" version
assert_eq "[dotsteward] ERROR: the state root must be an absolute path: relative/xdg/dotsteward" "$DS_STDERR"
assert_calls
instance_with $'[state]\nroot = "${XDG_DATA_HOME:-relative}/x"'
assert_exit 1 "$inst/.dotsteward/cli.sh" version
assert_eq "[dotsteward] ERROR: the state root must be an absolute path: relative/x" "$DS_STDERR"
instance_with $'[state]\nroot = "state-${XDG_DATA_HOME:-/data}"'
assert_exit 1 "$inst/.dotsteward/cli.sh" version
assert_eq "[dotsteward] ERROR: the state root must be an absolute path: state-\${XDG_DATA_HOME:-/data}" "$DS_STDERR"
assert_calls

# A root key in another table, or a commented one, is not state.root.
instance_with $'[other]\nroot = "/wrong"\n[state]\n# root = "/wrong-too"\n[more]\nroot = "/wrong-three"'
expect_root "$HOME/.local/state/dotsteward"

# DOTSTEWARD_STATE_ROOT wins; an empty value counts as unset.
instance_with $'[state]\nroot = "~/configured"'
expect_root "$r/explicit" DOTSTEWARD_STATE_ROOT="$r/explicit"
expect_root "$HOME/configured" DOTSTEWARD_STATE_ROOT=

# DOTFILES_STATE_ROOT only with [compat] legacy_env = true, and below
# DOTSTEWARD_STATE_ROOT.
instance_with $'[state]\nroot = "~/configured"\n\n[compat]\nlegacy_env = true # keep the old names'
expect_root "$r/legacy" DOTFILES_STATE_ROOT="$r/legacy"
expect_root "$r/explicit" DOTFILES_STATE_ROOT="$r/legacy" DOTSTEWARD_STATE_ROOT="$r/explicit"
expect_root "$HOME/configured" DOTFILES_STATE_ROOT=
instance_with ""
cat >"$inst/workstation.toml" <<EOF
schema_version = 1
compat.legacy_env = true

[identity]
username = "dotsteward-test"
EOF
expect_root "$r/legacy-dotted" DOTFILES_STATE_ROOT="$r/legacy-dotted"
instance_with $'[state]\nroot = "~/configured"\n[compat]\nlegacy_env = false'
expect_root "$HOME/configured" DOTFILES_STATE_ROOT="$r/legacy"
instance_with $'[state]\nroot = "~/configured"\n[other]\nlegacy_env = true\n[compat]\nlegacy_backup_layout = true'
expect_root "$HOME/configured" DOTFILES_STATE_ROOT="$r/legacy"
instance_with $'[compat]\n# legacy_env = true\nlegacy_envs = true'
expect_root "$HOME/.local/state/dotsteward" DOTFILES_STATE_ROOT="$r/legacy"

# Without workstation.toml the default applies.
instance_with ""
rm -- "$inst/workstation.toml"
expect_root "$HOME/.local/state/dotsteward"

# A relative state root is refused before any Nix call.
instance_with $'[state]\nroot = "relative/state"'
: >"$DS_CALL_LOG"
assert_exit 1 "$inst/.dotsteward/cli.sh" version
assert_eq "[dotsteward] ERROR: the state root must be an absolute path: relative/state" "$DS_STDERR"
assert_calls
DOTSTEWARD_STATE_ROOT=rel assert_exit 1 "$inst/.dotsteward/cli.sh" version
assert_eq "[dotsteward] ERROR: the state root must be an absolute path: rel" "$DS_STDERR"

# A new state root and its cache directory are private (0700).
instance_with ""
assert_exit 0 env DOTSTEWARD_STATE_ROOT="$r/fresh/state" "$inst/.dotsteward/cli.sh" version
assert_file_mode "$r/fresh/state" 700
assert_file_mode "$r/fresh/state/cli" 700
