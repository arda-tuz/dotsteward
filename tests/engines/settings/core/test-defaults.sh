# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and settings_* variables come from the harness and helpers.sh
# Defaults: the repository (--repo > DOTSTEWARD_INSTANCE > DOTFILES_ROOT
# with compat.legacy_env > the instance above the working directory), the
# state directory (--state-dir > DOTSTEWARD_STATE_ROOT > DOTFILES_STATE_ROOT
# with compat.legacy_env > state.root, each with /local-maintained-files),
# and settings.buffer_dir and settings.published_ref of workstation.toml.
# shellcheck source=tests/engines/settings/core/helpers.sh
source "$DS_REPO_ROOT/tests/engines/settings/core/helpers.sh"

minimal=$DS_REPO_ROOT/tests/nix/lib/fixtures/valid/minimal.toml

# make_instance DIR ID [TOML...]: an instance whose buffer lives in
# settings-buffer/ and tracks one key whose entry id is ID; every TOML
# argument is appended to workstation.toml.
make_instance() {
  local dir=$1 id=$2 extra
  shift 2
  mkdir -p "$dir/settings-buffer/files" "$dir/sub/dir"
  git init -q -b main "$dir"
  cp "$minimal" "$dir/workstation.toml"
  printf '\n[settings]\nbuffer_dir = "settings-buffer"\npublished_ref = "upstream/trunk"\n' \
    >>"$dir/workstation.toml"
  printf '\n[state]\nroot = "~/configured-state"\n' >>"$dir/workstation.toml"
  for extra in "$@"; do
    printf '\n%s\n' "$extra" >>"$dir/workstation.toml"
  done
  cat >"$dir/settings-buffer/buffer.toml" <<EOF
schema_version = 1

[targets.app]
path = "~/.config/app/settings.json"
format = "json"
create_if_missing = true

[[entries]]
id = "$id"
target = "app"
key = ["level"]
value = 1
EOF
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "chore: add the instance"
}

ids() {
  "$@" status --json | jq -r '[.entries[].id] | join(",")'
}

first=$DS_TEST_ROOT/first
second=$DS_TEST_ROOT/second
legacy=$DS_TEST_ROOT/legacy
make_instance "$first" first-key
make_instance "$second" second-key
make_instance "$legacy" legacy-key '[compat]
legacy_env = true'
mkdir -p "$DS_TEST_ROOT/outside"

# The repository.
assert_eq first-key "$(cd "$first/sub/dir" && ids settings)"
assert_eq second-key "$(cd "$first/sub/dir" && DOTSTEWARD_INSTANCE=$second ids settings)"
assert_eq first-key "$(cd "$DS_TEST_ROOT/outside" && DOTSTEWARD_INSTANCE=$second ids settings --repo "$first")"
assert_eq legacy-key "$(cd "$first" && DOTFILES_ROOT=$legacy ids settings)"
assert_eq first-key "$(cd "$first" && DOTFILES_ROOT=$second ids settings)" "DOTFILES_ROOT without legacy_env"
assert_eq second-key "$(cd "$first" && DOTFILES_ROOT=$legacy DOTSTEWARD_INSTANCE=$second ids settings)"
assert_eq second-key "$(cd "$DS_TEST_ROOT/outside" && ids "$DS_REPO_ROOT/cli/dotsteward" --instance "$second" settings)"
in_dir() {
  cd "$1" && shift && "$@"
}
assert_exit 2 in_dir "$DS_TEST_ROOT/outside" settings status
assert_contains "$DS_STDERR" "no instance found"

# The state directory.
apply_in() {
  (cd "$1" && shift && "$@" apply >/dev/null)
}
journal() {
  printf '%s/local-maintained-files/journal.jsonl\n' "$1"
}
apply_in "$first" settings
[[ -f $(journal "$DOTSTEWARD_STATE_ROOT") ]] || ds_fail "DOTSTEWARD_STATE_ROOT was not used"
unset DOTSTEWARD_STATE_ROOT
rm -rf "$HOME/.config/app"
apply_in "$first" settings
[[ -f $(journal "$HOME/configured-state") ]] || ds_fail "state.root was not used"
rm -rf "$HOME/.config/app"
apply_in "$first" env DOTFILES_STATE_ROOT="$DS_TEST_ROOT/ignored" "$DS_REPO_ROOT/cli/dotsteward" settings
[[ ! -e $DS_TEST_ROOT/ignored ]] || ds_fail "DOTFILES_STATE_ROOT was used without legacy_env"
rm -rf "$HOME/.config/app"
apply_in "$legacy" env DOTFILES_STATE_ROOT="$DS_TEST_ROOT/legacy-state" "$DS_REPO_ROOT/cli/dotsteward" settings
[[ -f $(journal "$DS_TEST_ROOT/legacy-state") ]] || ds_fail "DOTFILES_STATE_ROOT was not used with legacy_env"
rm -rf "$HOME/.config/app"
apply_in "$legacy" env DOTFILES_STATE_ROOT="$DS_TEST_ROOT/legacy-lost" DOTSTEWARD_STATE_ROOT="$DS_TEST_ROOT/new-state" \
  "$DS_REPO_ROOT/cli/dotsteward" settings
[[ -f $(journal "$DS_TEST_ROOT/new-state") && ! -e $DS_TEST_ROOT/legacy-lost ]] ||
  ds_fail "DOTSTEWARD_STATE_ROOT must win over DOTFILES_STATE_ROOT"
rm -rf "$HOME/.config/app"
apply_in "$first" settings --state-dir "$DS_TEST_ROOT/explicit"
[[ -f $DS_TEST_ROOT/explicit/journal.jsonl ]] || ds_fail "--state-dir was not used"
export DOTSTEWARD_STATE_ROOT=$DS_TEST_ROOT/state

# settings.published_ref and settings.buffer_dir: the base advances from
# upstream/trunk's settings-buffer/buffer.toml; origin does not exist.
git init -q --bare -b main "$DS_TEST_ROOT/upstream.git"
git -C "$first" remote add upstream "$DS_TEST_ROOT/upstream.git"
git -C "$first" push -q upstream main:trunk
git -C "$first" fetch -q upstream
assert_exit 0 settings --repo "$first" reconcile
assert_json - '.published_available == true and (.entries[0].base == {"value": 1}) and .repo_last_change != null' \
  <<<"$(settings --repo "$first" status --json)"
# Without that ref nothing is published (second has no remote).
assert_json - '.published_available == false and .entries[0].base == null' \
  <<<"$(settings --repo "$second" --state-dir "$DS_TEST_ROOT/second-state" status --json)"
# A repository without workstation.toml uses local-maintained-files/ and
# origin/main.
settings_repo "$DS_TEST_ROOT/plain"
assert_json - '[.entries[].id] | index("beta-threads") != null' \
  <<<"$(cd "$DS_TEST_ROOT/outside" && settings --repo "$DS_TEST_ROOT/plain" status --json)"

# An invalid workstation.toml is reported, not ignored.
printf 'schema_version = 1\n[settings]\nbuffer_dir = 7\n' >"$DS_TEST_ROOT/plain/workstation.toml"
assert_exit 2 settings --repo "$DS_TEST_ROOT/plain" status
assert_contains "$DS_STDERR" "settings.buffer_dir"
