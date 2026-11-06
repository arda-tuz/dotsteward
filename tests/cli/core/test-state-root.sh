# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The one state root: DOTSTEWARD_STATE_ROOT, then DOTFILES_STATE_ROOT with
# compat.legacy_env, then state.root of the instance, then the default of the
# schema. The Python package, the frozen bash library of hooks and the
# configuration loader give one answer for the same environment.
# shellcheck source=tests/cli/core/helpers.sh
source "$DS_REPO_ROOT/tests/cli/core/helpers.sh"

export DOTSTEWARD_LIB=$DS_REPO_ROOT/cli/lib
# The harness points the state root into the test root.
unset DOTSTEWARD_STATE_ROOT

# bash_root: the state root as a hook sees it, without an instance.
bash_root() {
  bash --noprofile --norc -c 'source "$DOTSTEWARD_LIB/lib.sh"; state_root'
}

# loaded_root DIR: the state root as a command sees it after config_load.
loaded_root() {
  bash --noprofile --norc -c '
    source "$DOTSTEWARD_LIB/lib.sh"
    source "$DOTSTEWARD_LIB/config.sh"
    config_load "$1"
    state_root
  ' bash "$1"
}

outside=$DS_TEST_ROOT/outside
mkdir -p "$outside"
cd "$outside" || ds_fail "no $outside"

# --- no instance ---------------------------------------------------------------

assert_eq "$HOME/.local/state/dotsteward" "$(internal state-root)" "the default"
assert_eq "$(bash_root)" "$(internal state-root)" "the default, bash and Python"
assert_eq "$DS_TEST_ROOT/xdg/dotsteward" "$(XDG_STATE_HOME=$DS_TEST_ROOT/xdg internal state-root)" "XDG_STATE_HOME"
assert_eq "$(XDG_STATE_HOME=$DS_TEST_ROOT/xdg bash_root)" "$(XDG_STATE_HOME=$DS_TEST_ROOT/xdg internal state-root)" \
  "XDG_STATE_HOME, bash and Python"
assert_eq "$DS_TEST_ROOT/chosen" "$(DOTSTEWARD_STATE_ROOT=$DS_TEST_ROOT/chosen internal state-root)" "the override"
assert_eq "$(DOTSTEWARD_STATE_ROOT=$DS_TEST_ROOT/chosen bash_root)" \
  "$(DOTSTEWARD_STATE_ROOT=$DS_TEST_ROOT/chosen internal state-root)" "the override, bash and Python"

relative() {
  DOTSTEWARD_STATE_ROOT=relative/state internal state-root
}
assert_exit 1 relative
assert_eq '[dotsteward] ERROR: DOTSTEWARD_STATE_ROOT: expected an absolute path, got "relative/state"' "$DS_STDERR"
assert_eq '' "$DS_STDOUT"

# --- an instance ------------------------------------------------------------------

inst=$DS_TEST_ROOT/inst
core_instance "$inst" '[state]
root = "~/.local/state/workstation"'
expected=$HOME/.local/state/workstation
assert_eq "$expected" "$(internal state-root --instance "$inst")" "state.root with --instance"
assert_eq "$expected" "$(DOTSTEWARD_INSTANCE=$inst internal state-root)" "state.root with DOTSTEWARD_INSTANCE"
assert_eq "$expected" "$(cd "$inst" && internal state-root)" "state.root of the instance above the working directory"
assert_eq "$expected" "$(loaded_root "$inst")" "state.root, config_load and Python"

assert_eq "$DS_TEST_ROOT/chosen" "$(DOTSTEWARD_STATE_ROOT=$DS_TEST_ROOT/chosen internal state-root --instance "$inst")" \
  "the override wins over state.root"
assert_eq "$DS_TEST_ROOT/chosen" "$(DOTSTEWARD_STATE_ROOT=$DS_TEST_ROOT/chosen loaded_root "$inst")" \
  "the override wins over state.root, config_load"

# The legacy variable counts only with compat.legacy_env, and the current one
# wins over it.
assert_eq "$expected" "$(DOTFILES_STATE_ROOT=$DS_TEST_ROOT/legacy internal state-root --instance "$inst")" \
  "DOTFILES_STATE_ROOT without compat.legacy_env"
legacy=$DS_TEST_ROOT/legacy-inst
core_instance "$legacy" '[compat]
legacy_env = true'
assert_eq "$DS_TEST_ROOT/legacy" "$(DOTFILES_STATE_ROOT=$DS_TEST_ROOT/legacy internal state-root --instance "$legacy")" \
  "DOTFILES_STATE_ROOT with compat.legacy_env"
assert_eq "$DS_TEST_ROOT/legacy" "$(DOTFILES_STATE_ROOT=$DS_TEST_ROOT/legacy loaded_root "$legacy")" \
  "DOTFILES_STATE_ROOT with compat.legacy_env, config_load"
assert_eq "$DS_TEST_ROOT/chosen" \
  "$(DOTSTEWARD_STATE_ROOT=$DS_TEST_ROOT/chosen DOTFILES_STATE_ROOT=$DS_TEST_ROOT/legacy internal state-root --instance "$legacy")" \
  "DOTSTEWARD_STATE_ROOT wins over DOTFILES_STATE_ROOT"

# A broken instance is an error, never the default in disguise; a state.root
# that expands to a relative path too.
broken=$DS_TEST_ROOT/broken
mkdir -p "$broken"
printf 'schema_version = = 1\n' >"$broken/workstation.toml"
assert_exit 1 internal state-root --instance "$broken"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: workstation.toml: invalid TOML: "
missing() {
  DOTSTEWARD_INSTANCE=$DS_TEST_ROOT/no-such-instance internal state-root
}
assert_exit 1 missing
assert_contains "$DS_STDERR" "DOTSTEWARD_INSTANCE: "
relative_inst=$DS_TEST_ROOT/relative-inst
core_instance "$relative_inst" '[state]
root = "relative/state"'
assert_exit 1 internal state-root --instance "$relative_inst"
assert_contains "$DS_STDERR" 'state.root'

# --- the Python interface -----------------------------------------------------------

core_python - "$inst" "$HOME" <<'PY' || ds_fail "config.state_root"
import sys

from dotsteward_cli import config

inst, home = sys.argv[1:]
instance = config.load_instance(inst, env={"HOME": home})
assert config.state_root(instance, env={"HOME": home}) == f"{home}/.local/state/workstation"
assert config.state_root(env={"HOME": home}) == f"{home}/.local/state/dotsteward"
assert config.state_root(env={"HOME": home, "XDG_STATE_HOME": "/synthetic"}) == "/synthetic/dotsteward"
assert config.state_root(instance, env={"HOME": home, "DOTSTEWARD_STATE_ROOT": "/chosen"}) == "/chosen"
assert config.runtime_values(instance, env={"HOME": home})["state_root"] == f"{home}/.local/state/workstation"
PY

# --- one definition ----------------------------------------------------------------

# Only the schema names the default; the package computes it in one place.
others=$(grep -rn 'XDG_STATE_HOME' "$DS_REPO_ROOT/cli/python" "$DS_REPO_ROOT/engines" --include='*.py' || true)
assert_eq "" "$others" "another definition of the state root"
