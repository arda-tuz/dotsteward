# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and settings_* variables come from the harness and helpers.sh
# Defaults: the repository (--repo > DOTSTEWARD_INSTANCE > DOTFILES_ROOT
# with compat.legacy_env > the instance above the working directory >
# --repo-default), the state directory (--state-dir > DOTSTEWARD_STATE_ROOT >
# DOTFILES_STATE_ROOT with compat.legacy_env > state.root, each with
# /local-maintained-files; without workstation.toml --state-dir-default
# comes before the built-in default), and settings.buffer_dir and
# settings.published_ref of workstation.toml.
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

# --repo-default (the checkout baked into the local-maintained-files alias)
# is the last resort: after --repo, the environment and the instance above
# the working directory.
assert_eq second-key "$(cd "$DS_TEST_ROOT/outside" && ids settings --repo-default "$second")"
assert_eq first-key "$(cd "$first/sub/dir" && ids settings --repo-default "$second")" "discovery wins"
assert_eq first-key "$(cd "$DS_TEST_ROOT/outside" && ids settings --repo-default "$second" --repo "$first")"
assert_eq first-key "$(cd "$DS_TEST_ROOT/outside" && DOTSTEWARD_INSTANCE=$first ids settings --repo-default "$second")"
assert_eq legacy-key "$(cd "$DS_TEST_ROOT/outside" && DOTFILES_ROOT=$legacy ids settings --repo-default "$second")"
# A stale DOTFILES_ROOT (no instance with legacy_env) falls back to it.
mkdir -p "$DS_TEST_ROOT/stale"
assert_eq legacy-key "$(cd "$DS_TEST_ROOT/outside" && DOTFILES_ROOT=$DS_TEST_ROOT/stale ids settings --repo-default "$legacy")" \
  "stale DOTFILES_ROOT"
# An invalid DOTSTEWARD_INSTANCE stays an error.
assert_exit 2 in_dir "$DS_TEST_ROOT/outside" env DOTSTEWARD_INSTANCE="$DS_TEST_ROOT/stale" \
  "$DS_REPO_ROOT/cli/dotsteward" settings --repo-default "$second" status
assert_contains "$DS_STDERR" "DOTSTEWARD_INSTANCE: no workstation.toml in $DS_TEST_ROOT/stale"

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

# --state-dir-default (baked into the alias) is the state directory of a
# repository without workstation.toml, after --state-dir and
# DOTSTEWARD_STATE_ROOT; an instance's own state.root comes first. apply
# takes the lock in the state directory it uses.
apply_in "$DS_TEST_ROOT/outside" settings --repo "$DS_TEST_ROOT/plain" --state-dir-default "$DS_TEST_ROOT/baked-plain"
[[ ! -e $DS_TEST_ROOT/baked-plain ]] || ds_fail "DOTSTEWARD_STATE_ROOT must win over --state-dir-default"
(
  unset DOTSTEWARD_STATE_ROOT
  apply_in "$DS_TEST_ROOT/outside" settings --repo "$DS_TEST_ROOT/plain" --state-dir-default "$DS_TEST_ROOT/baked-plain"
  [[ -f $DS_TEST_ROOT/baked-plain/lock ]] || ds_fail "--state-dir-default was not used"
  apply_in "$DS_TEST_ROOT/outside" settings --repo "$DS_TEST_ROOT/plain" --state-dir-default "$DS_TEST_ROOT/baked-plain" \
    --state-dir "$DS_TEST_ROOT/explicit-plain"
  [[ -f $DS_TEST_ROOT/explicit-plain/lock ]] || ds_fail "--state-dir must win over --state-dir-default"
  rm -rf "$HOME/.config/app"
  before=$(wc -l <"$(journal "$HOME/configured-state")")
  apply_in "$first" settings --state-dir-default "$DS_TEST_ROOT/baked-instance"
  (($(wc -l <"$(journal "$HOME/configured-state")") > before)) && [[ ! -e $DS_TEST_ROOT/baked-instance ]] ||
    ds_fail "state.root must win over --state-dir-default"
)

# An invalid workstation.toml is reported, not ignored.
printf 'schema_version = 1\n[settings]\nbuffer_dir = 7\n' >"$DS_TEST_ROOT/plain/workstation.toml"
assert_exit 2 settings --repo "$DS_TEST_ROOT/plain" status
assert_contains "$DS_STDERR" "settings.buffer_dir"
