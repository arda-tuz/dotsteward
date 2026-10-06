# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # literal ~ and $ text is single-quoted on purpose
# Stage-0 (the instance bootstrap.sh, SPEC 10.2) on a fresh Linux machine,
# in today's order: profile, identity, preflight (its JSON on standard
# output), backups of every declared path into
# <state>/backups/<UTC>/files/<absolute path>, snapshots whose required
# command exists, the missing prerequisites (platform base list plus the
# components' apt list) in one interactive apt transaction, the verified
# Nix install (exact size, then SHA-256, then a text file) and the exact
# `nix --version`, then `exec .dotsteward/cli.sh bootstrap --profile P
# --stage 1`. Runs with the macOS /bin/bash version (GNU bash 3.2.57, when
# the caller provides it as DS_BASH32) and with the current bash, without
# Nix, jq or python3 on PATH.
# shellcheck source=tests/cli/bootstrap/helpers.sh
source "$DS_REPO_ROOT/tests/cli/bootstrap/helpers.sh"

ds_use_stubs sudo apt-get dpkg-query curl example-app

stage0_env_set linux \
  "DS_STAGE0_BACKUP_PATHS=('~/.config/nix/nix.conf' '~/.agents/skills' '~/.config/missing.toml' '~/.config/link.toml' '$DS_SYSTEM_ROOT/etc/example.conf' '~/.config/nix/nix.conf')" \
  "DS_STAGE0_SNAPSHOTS=(example-app-state never-taken)" \
  "DS_STAGE0_SNAPSHOT_0_ARGV=(example-app dump 'all state')" \
  "DS_STAGE0_SNAPSHOT_0_REQUIRE_COMMAND=example-app" \
  "DS_STAGE0_SNAPSHOT_1_ARGV=(missing-tool-of-the-test dump)" \
  "DS_STAGE0_SNAPSHOT_1_REQUIRE_COMMAND=missing-tool-of-the-test" \
  "DS_STAGE0_PREREQUISITES_APT=(example-app-deps git)"
ds_stub_route example-app "dump all state" --stdout "example state"

# reset: a fresh machine again (no Nix, no backups, packages as shipped).
reset() {
  rm -rf -- "$DOTSTEWARD_STATE_ROOT/backups" "$HOME/.nix-profile" "$HOME/.config" "$HOME/.agents" \
    "$DS_STUB_STATE/dpkg"
  : >"$DS_CALL_LOG"
  ds_dpkg_installed ca-certificates 20240203
  ds_dpkg_installed git 1:2.43.0-1ubuntu7
  local package
  for package in ca-certificates curl git gnupg xz-utils example-app-deps; do
    ds_apt_available "$package" 1.0
  done
  mkdir -p "$HOME/.config/nix" "$HOME/.agents/skills/example-skill" "$DS_SYSTEM_ROOT/etc"
  printf 'experimental-features = nix-command\n' >"$HOME/.config/nix/nix.conf"
  chmod 0644 "$HOME/.config/nix/nix.conf"
  printf -- '---\nname: example-skill\n---\n' >"$HOME/.agents/skills/example-skill/SKILL.md"
  ln -sfn nix/nix.conf "$HOME/.config/link.toml"
  printf 'system file\n' >"$DS_SYSTEM_ROOT/etc/example.conf"
}

# line_of PATTERN: the first call-log line number matching the ERE.
line_of() {
  local number
  number=$(grep -n -E -m 1 -e "$1" "$DS_CALL_LOG" | cut -d: -f1) || true
  [[ -n $number ]] || ds_fail "no call matching [$1] in [$(<"$DS_CALL_LOG")]"
  printf '%s\n' "$number"
}

shells=("$BASH")
if [[ -n ${DS_BASH32:-} ]]; then
  shells+=("$DS_BASH32")
fi

for shell in "${shells[@]}"; do
  reset
  bs_bash=$shell
  assert_exit 0 run_stage0 -- --profile fresh

  # Preflight first: its document is the first thing on standard output.
  document=$(sed -n '1,/^}$/p' <<<"$DS_STDOUT")
  free=$(preflight_free_kib "$document")
  assert_eq "$(expected_preflight_json fresh fast true ubuntu 24.04 "$bs_arch" unknown null "$free" true)" \
    "$document" "preflight document ($shell)"

  # Backups: one private directory, files/<absolute path>, regular files
  # 0600, symlinks kept as symlinks, absent paths skipped, each path once.
  mapfile -t dirs < <(backup_dirs)
  assert_eq 1 "${#dirs[@]}" "one backup directory"
  backup=${dirs[0]}
  [[ ${backup##*/} =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || ds_fail "backup directory is not a UTC timestamp: $backup"
  assert_file_mode "$backup" 700
  assert_eq 'experimental-features = nix-command' "$(<"$backup/files$HOME/.config/nix/nix.conf")"
  assert_file_mode "$backup/files$HOME/.config/nix/nix.conf" 600
  assert_eq $'---\nname: example-skill\n---' "$(<"$backup/files$HOME/.agents/skills/example-skill/SKILL.md")"
  assert_symlink_to "$backup/files$HOME/.config/link.toml" nix/nix.conf
  [[ ! -e $backup/files$HOME/.config/missing.toml ]] || ds_fail "an absent path was backed up"
  assert_eq 'system file' "$(<"$backup/files$DS_SYSTEM_ROOT/etc/example.conf")"
  assert_contains "$DS_STDOUT" "[dotsteward] backing up existing files to $backup"

  # Snapshots: only those whose required command exists, private.
  assert_eq 'example state' "$(<"$backup/snapshots/example-app-state")"
  assert_file_mode "$backup/snapshots/example-app-state" 600
  [[ ! -e $backup/snapshots/never-taken ]] || ds_fail "a snapshot without its command was taken"
  assert_eq "example-app dump all\\ state" "$(ds_calls_of example-app)"

  # Prerequisites: the platform base list plus the component list, the
  # missing ones in one transaction, without -y (D6).
  assert_eq "sudo apt-get update
sudo apt-get install --no-install-recommends curl gnupg xz-utils example-app-deps" "$(ds_calls_of sudo)"
  assert_contains "$DS_STDOUT" "[dotsteward] installing the missing prerequisites: curl gnupg xz-utils example-app-deps"
  [[ $(ds_dpkg_version example-app-deps) == 1.0 ]] || ds_fail "the prerequisites were not installed"

  # The verified installer ran in multi-user mode and Nix answers with the
  # pinned version; the download directory is gone.
  assert_contains "$(ds_calls_of curl)" "--proto =https"
  assert_contains "$(ds_calls_of curl)" "$bs_installer_url"
  assert_contains "$(<"$DS_CALL_LOG")" "nix-installer --daemon"
  assert_contains "$DS_STDOUT" "[dotsteward] starting the verified Nix 2.35.2 multi-user installer"
  [[ -x $HOME/.nix-profile/bin/nix ]] || ds_fail "Nix was not installed"
  assert_eq "" "$(find "$TMPDIR" -maxdepth 1 -name 'dotsteward-nix.*')" "installer directory removed"

  # Stage 1 through the launcher, last.
  assert_eq "cli.sh bootstrap --profile fresh --stage 1" "$(ds_calls_of cli.sh)"
  order=(
    "$(line_of '^example-app dump')"
    "$(line_of '^sudo apt-get update')"
    "$(line_of '^curl ')"
    "$(line_of '^nix-installer ')"
    "$(line_of '^cli\.sh ')"
  )
  for ((i = 1; i < ${#order[@]}; i++)); do
    ((order[i - 1] < order[i])) || ds_fail "stage-0 steps out of order: ${order[*]} in [$(<"$DS_CALL_LOG")]"
  done
done

# DOTSTEWARD_ASSUME_YES=1 (CI and VM harnesses only) answers apt and the
# Nix installer.
reset
assert_exit 0 run_stage0 DOTSTEWARD_ASSUME_YES=1 -- --profile fresh
assert_eq "sudo apt-get update
sudo apt-get install -y --no-install-recommends curl gnupg xz-utils example-app-deps" "$(ds_calls_of sudo)"
assert_contains "$(<"$DS_CALL_LOG")" "nix-installer --daemon --yes"

# A machine that already has the prerequisites and the pinned Nix: no apt,
# no download, straight to stage 1.
reset
for package in curl gnupg xz-utils example-app-deps; do
  ds_dpkg_installed "$package" 1.0
done
mkdir -p "$HOME/.nix-profile/bin"
printf '#!%s\nprintf "nix (Nix) 2.35.2\\n"\n' "$BASH" >"$HOME/.nix-profile/bin/nix"
chmod 0755 "$HOME/.nix-profile/bin/nix"
assert_exit 0 run_stage0 -- --profile fresh
assert_eq "" "$(ds_calls_of sudo)" "no apt transaction"
assert_eq "" "$(ds_calls_of curl)" "no download"
assert_not_contains "$(<"$DS_CALL_LOG")" "nix-installer"
assert_eq "cli.sh bootstrap --profile fresh --stage 1" "$(ds_calls_of cli.sh)"
assert_json - '.nix_version == "2.35.2"' <<<"$(sed -n '1,/^}$/p' <<<"$DS_STDOUT")"

# The state root: DOTSTEWARD_STATE_ROOT, else the mirror's state.root with
# ${XDG_STATE_HOME:-...} and ~ expanded, else DOTFILES_STATE_ROOT only with
# the legacy environment.
reset
assert_exit 0 run_stage0 -u DOTSTEWARD_STATE_ROOT XDG_STATE_HOME="$DS_TEST_ROOT/xdg" -- --profile fresh
[[ -d $DS_TEST_ROOT/xdg/dotsteward/backups ]] || ds_fail "backups not below \$XDG_STATE_HOME/dotsteward"
reset
assert_exit 0 run_stage0 -u DOTSTEWARD_STATE_ROOT -- --profile fresh
[[ -d $HOME/.local/state/dotsteward/backups ]] || ds_fail "backups not below ~/.local/state/dotsteward"
reset
assert_exit 0 run_stage0 -u DOTSTEWARD_STATE_ROOT DOTFILES_STATE_ROOT="$DS_TEST_ROOT/legacy" -- --profile fresh
[[ ! -e $DS_TEST_ROOT/legacy ]] || ds_fail "DOTFILES_STATE_ROOT used without the legacy environment"
stage0_env_set linux "DS_STAGE0_LEGACY_ENV=true" "DS_STAGE0_STATE_ROOT='~/.local/state/dotfiles'"
reset
assert_exit 0 run_stage0 -u DOTSTEWARD_STATE_ROOT DOTFILES_STATE_ROOT="$DS_TEST_ROOT/legacy" -- --profile fresh
[[ -d $DS_TEST_ROOT/legacy/backups ]] || ds_fail "DOTFILES_STATE_ROOT ignored with the legacy environment"
reset
assert_exit 0 run_stage0 -u DOTSTEWARD_STATE_ROOT -- --profile fresh
[[ -d $HOME/.local/state/dotfiles/backups ]] || ds_fail "state.root with ~ not expanded"
