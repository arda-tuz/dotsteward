#!/usr/bin/env bash
# summary: Build the instance's Home Manager generation for this machine and optionally switch to it
#
# Port of rebuild.sh (SPEC 6.2, F5). Order:
#   1. guards: flags, profile, identity, a host-flake-safe checkout that is
#      the root of a clean git repository (untracked files refused: Nix does
#      not see them), the instance flake.lock; nothing is written before
#   2. host overrides in <state>/host-overrides: profile.nix (the runtime
#      $USER and $HOME, SPEC 4.4), flake.nix (input [compat] host_input of
#      type path: and homeConfigurations.current = <input>.lib.mkHome
#      (import ./profile.nix)) and the host input lock, created when missing
#      and refreshed only when (canonical_revision, canonical_repo) of
#      inventory.json changed or the last run used a framework override
#   3. inventory.json, the build (never updating a lock file), the records
#      <state>/current/last-built-activation and <state>/current/profile;
#      --build-only stops here
#   4. preActivate hooks of the built generation's manifest, the previous
#      generation capture (once; ABSENT when no Home Manager generation
#      exists), adoption of the manifest's adopt paths, activate, the
#      generation's local-maintained-files apply, agents install, login
#      shell migrate, and the check that the instance flake.lock is
#      unchanged
# A framework override (--framework-override REF or
# DOTSTEWARD_FRAMEWORK_OVERRIDE; the flag wins) builds with
# --override-input <host_input>/dotsteward REF and the instance checkout as
# <host_input>, writes no lock file, leaves the host lock alone and is
# recorded in inventory.json.
set -Eeuo pipefail

# shellcheck source=cli/lib/lib.sh
source "$DOTSTEWARD_LIB/lib.sh"
# shellcheck source=cli/lib/config.sh
source "$DOTSTEWARD_LIB/config.sh"
# shellcheck source=cli/lib/methods.sh
source "$DOTSTEWARD_LIB/methods.sh"

usage() {
  cat <<'EOF'
Usage: dotsteward rebuild --profile PROFILE --switch|--build-only
                          [--framework-override REF]

Builds the Home Manager generation of PROFILE for the running user and home
through the machine's host flake (<state>/host-overrides). --build-only
stops after the build and changes nothing outside the state directory.
--switch then runs the preActivate hooks, adopts the declared files,
activates the generation, applies the tracked settings, installs the agent
tools and moves a versioned login shell to the stable path.

  --profile PROFILE          a profile of the instance (required)
  --switch                   activate the built generation
  --build-only               build only (with --switch, --switch wins)
  --framework-override REF   build with the framework at the flake
                             reference REF instead of the locked one,
                             without writing a lock file (default:
                             DOTSTEWARD_FRAMEWORK_OVERRIDE)

The instance must be the root of a git repository without uncommitted
changes or untracked files.

Exit status: 0 done, 1 refusal, or the status of a failed step.
EOF
}

profile=''
do_switch=0
build_only=0
framework_override=${DOTSTEWARD_FRAMEWORK_OVERRIDE:-}
while (($#)); do
  case $1 in
    --profile | --framework-override)
      if (($# < 2)) || [[ -z $2 ]]; then
        die "rebuild: $1 requires a value"
      fi
      if [[ $1 == --profile ]]; then
        profile=$2
      else
        framework_override=$2
      fi
      shift 2
      ;;
    --profile=*)
      profile=${1#--profile=}
      [[ -n $profile ]] || die "rebuild: --profile requires a value"
      shift
      ;;
    --framework-override=*)
      framework_override=${1#--framework-override=}
      [[ -n $framework_override ]] || die "rebuild: --framework-override requires a value"
      shift
      ;;
    --switch)
      do_switch=1
      shift
      ;;
    --build-only)
      build_only=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "rebuild: unknown option: $1" ;;
    *) die "rebuild: unexpected argument: $1" ;;
  esac
done
[[ -n $profile ]] || die "rebuild: --profile is required"
((do_switch || build_only)) || die "rebuild: --switch or --build-only is required"

# --- Guards (nothing is written before they pass) -------------------------

# shellcheck disable=SC2119 # the instance comes from --instance or discovery
config_load
require_profile "$profile"
require_safe_identity

repo_path=$(cd -P -- "$DS_INSTANCE_ROOT" && pwd)
host_input=${DS_COMPAT_HOST_INPUT:-instance}
[[ $host_input =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || die "invalid [compat] host_input: $host_input"
# The checkout is written into a Nix string and a flake reference.
[[ $repo_path != *[[:space:][:cntrl:]\"\'\\\$#?%]* ]] ||
  die "unsafe instance path for the host flake: $repo_path"

git_top=$(git -C "$repo_path" rev-parse --show-toplevel 2>/dev/null) || git_top=''
if [[ -z $git_top || $(cd -P -- "$git_top" && pwd) != "$repo_path" ]]; then
  die "the instance is not the root of a git repository: $repo_path"
fi
git_status=$(git -C "$repo_path" status --porcelain) ||
  die "cannot read the git status of the instance: $repo_path"
untracked=()
changed=()
while IFS= read -r line; do
  [[ -n $line ]] || continue
  if [[ $line == '?? '* ]]; then
    untracked+=("${line:3}")
  else
    changed+=("${line:3}")
  fi
done <<<"$git_status"
if ((${#untracked[@]})); then
  die "Nix does not see untracked files; run 'git add -A' first: ${untracked[*]}"
fi
if ((${#changed[@]})); then
  die "the instance repository is not clean; review and commit the changes first: ${changed[*]}"
fi
instance_lock=$repo_path/flake.lock
[[ -f $instance_lock ]] || die "instance flake.lock not found: $instance_lock"

source_nix_daemon
for tool in nix jq git realpath sha256sum; do
  require_command "$tool"
done

canonical_lock_before=$(sha256_file "$instance_lock")
canonical_revision=$(git -C "$repo_path" rev-parse --verify HEAD)

# assert_instance_lock_unchanged: nothing in the run may change the
# instance flake.lock.
assert_instance_lock_unchanged() {
  [[ -f $instance_lock && $(sha256_file "$instance_lock") == "$canonical_lock_before" ]] ||
    die "instance flake.lock changed unexpectedly: $instance_lock"
}

# write_private FILE: standard input into FILE, created with mode 0600.
write_private() {
  (umask 077 && cat >"$1") || return
  chmod 0600 -- "$1"
}

# --- Host overrides and the host input lock -------------------------------

state=$(state_root)
override_dir=$state/host-overrides
current_state_dir=$state/current
ensure_private_dir "$state" || die "cannot create the state directory: $state"
ensure_private_dir "$override_dir" || die "cannot create the host overrides directory: $override_dir"
ensure_private_dir "$current_state_dir" || die "cannot create the state directory: $current_state_dir"

inventory=$override_dir/inventory.json
host_lock=$override_dir/flake.lock
previous_revision=''
previous_repo=''
previous_override=''
if [[ -f $inventory ]] && jq -e . "$inventory" >/dev/null 2>&1; then
  previous_revision=$(jq -r '.canonical_revision // empty' "$inventory")
  previous_repo=$(jq -r '.canonical_repo // empty' "$inventory")
  previous_override=$(jq -r '.framework_override // empty' "$inventory")
fi

write_private "$override_dir/profile.nix" <<EOF
{
  username = "$USER";
  homeDirectory = "$HOME";
  profile = "$profile";
}
EOF

write_private "$override_dir/flake.nix" <<EOF
{
  inputs.$host_input.url = "path:$repo_path";

  outputs = { self, $host_input }:
    let
      profile = import ./profile.nix;
    in
    {
      homeConfigurations.current = $host_input.lib.mkHome profile;
    };
}
EOF

if [[ -n $framework_override ]]; then
  log "framework override $framework_override: the host input lock is not refreshed"
else
  if [[ -f $host_lock ]]; then
    if [[ $previous_revision != "$canonical_revision" || $previous_repo != "$repo_path" || -n $previous_override ]]; then
      log "instance source changed; refreshing the host input lock"
      nix_cmd flake update "$host_input" --flake "$override_dir"
    else
      log "instance source unchanged; keeping the host input lock"
    fi
  else
    log "creating the host input lock"
    nix_cmd flake lock "$override_dir"
  fi
  [[ -f $host_lock ]] || die "the host input lock was not written: $host_lock"
  chmod 0600 -- "$host_lock"
fi

jq -n \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg username "$USER" \
  --arg home "$HOME" \
  --arg profile "$profile" \
  --arg repo "$repo_path" \
  --arg revision "$canonical_revision" \
  --arg override "$framework_override" \
  '{schema_version: "1.0", generated_at: $generated_at, username: $username, home: $home,
    profile: $profile, canonical_repo: $repo, canonical_revision: $revision,
    tracked_repo_mutation: false,
    framework_override: (if $override == "" then null else $override end)}' |
  write_private "$inventory"
assert_instance_lock_unchanged

# --- Build and records ----------------------------------------------------

build_args=("$override_dir#homeConfigurations.current.activationPackage" --no-link)
if [[ -n $framework_override ]]; then
  build_args+=(
    --override-input "$host_input" "path:$repo_path"
    --override-input "$host_input/dotsteward" "$framework_override"
    --no-write-lock-file
  )
else
  build_args+=(--no-update-lock-file)
fi
build_args+=(--print-out-paths)

log "building the Home Manager activation package"
activation_path=$(nix_cmd build "${build_args[@]}")
[[ -x $activation_path/activate ]] || die "activation script not found: $activation_path/activate"
printf '%s\n' "$activation_path" | write_private "$current_state_dir/last-built-activation"
printf '%s\n' "$profile" | write_private "$current_state_dir/profile"

if ((!do_switch)); then
  log "build finished; the user state was not changed"
  exit 0
fi

# --- Switch ---------------------------------------------------------------

methods_manifest_load "$activation_path"
store_dir=${NIX_STORE_DIR:-/nix/store}

# preActivate hooks: a failing hook ends the rebuild with its status. The
# hooks keep the command's standard input (a hook may ask for a
# confirmation).
hooks_text=$(methods_hooks pre_activate "$profile")
mapfile -t hooks <<<"$hooks_text"
for hook in "${hooks[@]}"; do
  [[ -n $hook ]] || continue
  hook_status=0
  methods_run_hook "$hook" "$profile" 0 || hook_status=$?
  if ((hook_status != 0)); then
    printf '[dotsteward] ERROR: component %s hook %s failed (exit %s)\n' \
      "$(jq -r '.component' <<<"$hook")" "$(jq -r '.name' <<<"$hook")" "$hook_status" >&2
    exit "$hook_status"
  fi
done

# home_manager_generation: the generation the Home Manager profile points
# at, nothing when there is none (a dangling profile link included).
home_manager_generation() {
  local candidate
  for candidate in \
    "${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager" \
    "${NIX_STATE_DIR:-/nix/var/nix}/profiles/per-user/$USER/home-manager"; do
    if [[ -e $candidate ]]; then
      realpath -e -- "$candidate"
      return 0
    fi
  done
}

# The state before the first activation, recorded once for rollback.
previous_generation_file=$current_state_dir/previous-generation
if [[ ! -f $previous_generation_file ]]; then
  previous_generation=$(home_manager_generation)
  printf '%s\n' "${previous_generation:-ABSENT}" | write_private "$previous_generation_file"
fi

# expand_host_path PATH: ~/x is below $HOME, absolute paths stay.
expand_host_path() {
  case $1 in
    \~/*) printf '%s/%s\n' "$HOME" "${1#\~/}" ;;
    /*) printf '%s\n' "$1" ;;
    *) die "invalid host path in the manifest: $1" ;;
  esac
}

# Adoption: Home Manager does not replace a regular file it did not create
# (it stops when the content differs), so a file at a path the generation
# takes over is backed up and removed first. Every path is checked before
# the first one changes.
mapfile -t adopt_raw < <(jq -r '.adopt_paths[]' <<<"$DS_MANIFEST_JSON")
adopt_files=()
for raw in "${adopt_raw[@]}"; do
  path=$(expand_host_path "$raw")
  if [[ -L $path ]]; then
    target=$(readlink -f -- "$path") || die "adopt path is a broken link: $path"
    [[ $target == "$store_dir"/* ]] || die "adopt path points outside the Nix store: $path -> $target"
  elif [[ -e $path ]]; then
    [[ -f $path ]] || die "adopt path is not a regular file: $path"
    adopt_files+=("$path")
  fi
done
if ((${#adopt_files[@]})); then
  backup_root=$state/backups/$(timestamp_utc)-adopt
  ensure_private_dir "$backup_root" || die "cannot create the backup directory: $backup_root"
  for path in "${adopt_files[@]}"; do
    backup_file_private "$path" "$backup_root" || die "cannot back up: $path"
    rm -f -- "$path"
    log "previous file backed up and handed over to Home Manager: $path"
  done
fi

log "activating the Home Manager generation"
"$activation_path/activate"

# Tracked settings: only entries changed remotely and entries met for the
# first time are written to the live files; local changes and conflicts are
# left alone. The generation's command carries its own settings targets.
settings_command=$activation_path/home-path/bin/local-maintained-files
if [[ -x $settings_command ]]; then
  "$settings_command" --repo "$repo_path" --state-dir "$state/local-maintained-files" apply
else
  warn "the generation has no local-maintained-files command; the settings apply is skipped"
fi

cli=$DOTSTEWARD_FRAMEWORK_ROOT/cli/dotsteward
"$cli" --instance "$repo_path" agents install --profile "$profile" --generation "$activation_path"
"$cli" --instance "$repo_path" login-shell migrate --profile "$profile" --generation "$activation_path"
assert_instance_lock_unchanged
log "rebuild finished: $profile"
