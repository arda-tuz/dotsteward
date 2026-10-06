# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh and config_load
# Instance discovery (SPEC 6.1): --instance > DOTSTEWARD_INSTANCE >
# (DOTFILES_ROOT when its workstation.toml sets compat.legacy_env) > the
# nearest workstation.toml above the working directory. Exercised through
# config_load, the Python reader's discover command and, end to end, the
# dispatcher's --instance flag.
# shellcheck source=tests/cli/config/helpers.sh
source "$DS_REPO_ROOT/tests/cli/config/helpers.sh"

fw=$DS_TEST_ROOT/framework
make_framework "$fw"
first=$DS_TEST_ROOT/first
second=$DS_TEST_ROOT/second
legacy=$DS_TEST_ROOT/legacy
plain=$DS_TEST_ROOT/plain
make_instance "$first"
make_instance "$second"
make_instance "$legacy"
printf '[compat]\nlegacy_env = true\n' >>"$legacy/workstation.toml"
make_instance "$plain"
mkdir -p "$first/deep/er" "$DS_TEST_ROOT/outside"

discover() {
  (cd "$1" && shift && config_py discover "$@")
}

# Walk up from the working directory.
assert_eq "$first" "$(discover "$first")"
assert_eq "$first" "$(discover "$first/deep/er")"
# DOTSTEWARD_INSTANCE wins over the working directory, --instance over both.
assert_eq "$second" "$(DOTSTEWARD_INSTANCE=$second discover "$first/deep")"
assert_eq "$plain" "$(DOTSTEWARD_INSTANCE=$second discover "$first/deep" --instance "$plain")"
# DOTFILES_ROOT counts only when its configuration sets compat.legacy_env,
# and only below DOTSTEWARD_INSTANCE.
assert_eq "$legacy" "$(DOTFILES_ROOT=$legacy discover "$first")"
assert_eq "$first" "$(DOTFILES_ROOT=$plain discover "$first")"
assert_eq "$second" "$(DOTFILES_ROOT=$legacy DOTSTEWARD_INSTANCE=$second discover "$first")"
assert_eq "$legacy" "$(DOTFILES_ROOT=$legacy discover "$DS_TEST_ROOT/outside")"
# An unusable DOTFILES_ROOT (missing, broken TOML) is ignored like any
# DOTFILES_* name without legacy_env.
assert_eq "$first" "$(DOTFILES_ROOT=$DS_TEST_ROOT/missing discover "$first")"
mkdir -p "$DS_TEST_ROOT/broken"
printf 'schema_version = = 1\n' >"$DS_TEST_ROOT/broken/workstation.toml"
assert_eq "$first" "$(DOTFILES_ROOT=$DS_TEST_ROOT/broken discover "$first")"
# Empty variables count as unset.
assert_eq "$first" "$(DOTSTEWARD_INSTANCE='' DOTFILES_ROOT='' discover "$first")"

# The physical directory is reported.
ln -s "$second" "$DS_TEST_ROOT/second-link"
assert_eq "$second" "$(discover "$DS_TEST_ROOT/outside" --instance "$DS_TEST_ROOT/second-link")"
assert_eq "$second" "$(DOTSTEWARD_INSTANCE=$DS_TEST_ROOT/second-link discover "$DS_TEST_ROOT/outside")"

# Failures name the source of the directory.
assert_exit 1 discover "$DS_TEST_ROOT/outside"
assert_eq "[dotsteward] ERROR: no instance found: no workstation.toml in $DS_TEST_ROOT/outside or its parent directories (use --instance DIR or DOTSTEWARD_INSTANCE)" \
  "$DS_STDERR"
assert_exit 1 discover "$first" --instance "$DS_TEST_ROOT/outside"
assert_eq "[dotsteward] ERROR: --instance: no workstation.toml in $DS_TEST_ROOT/outside" "$DS_STDERR"
missing_instance() {
  DOTSTEWARD_INSTANCE=$DS_TEST_ROOT/missing discover "$first"
}
assert_exit 1 missing_instance
assert_eq "[dotsteward] ERROR: DOTSTEWARD_INSTANCE: not a directory: $DS_TEST_ROOT/missing" "$DS_STDERR"

# config_load: an argument, then the environment, then the working
# directory; DOTSTEWARD_INSTANCE is exported with the result.
cd "$first/deep" || exit 1
load_config "$fw"
assert_eq "$first" "$DS_INSTANCE_ROOT"
assert_eq "$first" "$DOTSTEWARD_INSTANCE"
load_config "$fw" "$second"
assert_eq "$second" "$DS_INSTANCE_ROOT"
assert_eq "$second" "$DOTSTEWARD_INSTANCE"
# The exported DOTSTEWARD_INSTANCE now selects the second instance.
load_config "$fw"
assert_eq "$second" "$DS_INSTANCE_ROOT"
unset DOTSTEWARD_INSTANCE
DOTFILES_ROOT=$legacy load_config "$fw"
assert_eq "$legacy" "$DS_INSTANCE_ROOT"
unset DOTSTEWARD_INSTANCE
cd "$DS_TEST_ROOT/outside" || exit 1
assert_exit 1 load_config "$fw"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: no instance found"

# End to end through the dispatcher: --instance reaches config_load.
cat >"$fw/cli/commands/show-instance.sh" <<'EOF'
#!/usr/bin/env bash
# summary: print the instance root (test command)
set -Eeuo pipefail
# shellcheck source=/dev/null
source "$DOTSTEWARD_LIB/lib.sh"
# shellcheck source=/dev/null
source "$DOTSTEWARD_LIB/config.sh"
config_load
printf '%s %s\n' "$DS_INSTANCE_ROOT" "$DS_INSTANCE_NAME"
EOF
assert_exit 0 "$fw/cli/dotsteward" --instance "$second" show-instance
assert_eq "$second second" "$DS_STDOUT"
cd "$first/deep/er" || exit 1
assert_exit 0 "$fw/cli/dotsteward" show-instance
assert_eq "$first first" "$DS_STDOUT"
cd "$DS_TEST_ROOT/outside" || exit 1
assert_exit 1 "$fw/cli/dotsteward" show-instance
assert_contains "$DS_STDERR" "[dotsteward] ERROR: no instance found"
