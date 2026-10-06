#!/usr/bin/env bash
# summary: Undo the instance's Home Manager setup (login shell, managed links, force-linked files)
#
# Port of rollback.sh (SPEC 6.2). The plan comes from the current
# generation's manifest (the active Home Manager generation, else the
# instance's mirror) and the records of rebuild in <state>/current:
#   1. login shell      when the instance manages one: the platform default
#                       (Linux /bin/bash, macOS /bin/zsh)
#   2. shells line      the line this system added to the shells file
#                       (etc-shells-added-path), when it is still listed
#   3. Home Manager     previous-generation ABSENT (no Home Manager before
#                       the first install): the managed links into the Nix
#                       store are removed; otherwise the recorded previous
#                       generation is activated
#   4. restore          each force-linked file from its newest backup, with
#                       its mode; without a backup it is skipped
#   5, 6. settings files synced by local-maintained-files, Nix, the packages
#                       and user data stay
# Everything that can refuse (a missing record, an invalid previous
# generation, a user file or a foreign link at a managed link) is checked
# before the first change.
set -Eeuo pipefail

# shellcheck source=cli/lib/lib.sh
source "$DOTSTEWARD_LIB/lib.sh"
# shellcheck source=cli/lib/config.sh
source "$DOTSTEWARD_LIB/config.sh"
# shellcheck source=cli/lib/methods.sh
source "$DOTSTEWARD_LIB/methods.sh"
# shellcheck source=cli/lib/skills.sh
source "$DOTSTEWARD_LIB/skills.sh"

usage() {
  cat <<'EOF'
Usage: dotsteward rollback --latest --dry-run [--json]
       dotsteward rollback --latest --apply

Undoes the instance's Home Manager setup: restores the platform default
login shell, removes the shells-file line this system added, removes the
managed links (no Home Manager before the first install) or activates the
recorded previous Home Manager generation, and restores the force-linked
files from their backups. Settings files, Nix, the packages and user data
stay.

  --latest    roll back to the state before the first install (required)
  --dry-run   print the plan and change nothing
  --json      with --dry-run: print the plan as JSON (step ids and paths)
  --apply     roll back

Exit status: 0 done, 1 refusal, or the status of a failed step.
EOF
}

use_latest=0
dry_run=0
apply=0
json=0
while (($#)); do
  case $1 in
    --latest) use_latest=1 ;;
    --dry-run) dry_run=1 ;;
    --apply) apply=1 ;;
    --json) json=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "rollback: unknown option: $1" ;;
    *) die "rollback: unexpected argument: $1" ;;
  esac
  shift
done
((use_latest)) || die "rollback: only --latest is supported"
((dry_run || apply)) || die "rollback: --dry-run or --apply is required"
((!(dry_run && apply))) || die "rollback: --dry-run and --apply cannot be combined"
((!json || dry_run)) || die "rollback: --json requires --dry-run"

# shellcheck disable=SC2119 # the instance comes from --instance or discovery
config_load
methods_manifest_load "$(skills_active_generation)"

store_dir=${NIX_STORE_DIR:-/nix/store}
current_dir=$(state_root)/current
previous_generation_file=$current_dir/previous-generation
shells_record=$current_dir/etc-shells-added-path

case $DS_RUNTIME_PLATFORM in
  darwin) default_shell=/bin/zsh ;;
  *) default_shell=/bin/bash ;;
esac

# expand_host_path PATH: ~/x is below $HOME, absolute paths stay.
expand_host_path() {
  case $1 in
    \~/*) printf '%s/%s\n' "$HOME" "${1#\~/}" ;;
    /*) printf '%s\n' "$1" ;;
    *) die "invalid host path in the manifest: $1" ;;
  esac
}

# --- Plan -----------------------------------------------------------------

login_shell_managed=0
if jq -e '.login_shell != null' <<<"$DS_MANIFEST_JSON" >/dev/null; then
  login_shell_managed=1
fi

if declare -F platform_shells_file >/dev/null; then
  shells_file=$(platform_shells_file)
else
  shells_file=/etc/shells
fi
shells_line=''
if [[ -f $shells_record ]]; then
  recorded=$(<"$shells_record")
  if [[ -n $recorded ]] && declare -F platform_shells_contains >/dev/null &&
    platform_shells_contains "$recorded"; then
    shells_line=$recorded
  fi
fi

previous_generation=''
recorded_previous=0
if [[ -f $previous_generation_file ]]; then
  previous_generation=$(<"$previous_generation_file")
  recorded_previous=1
fi

managed_links=()
mapfile -t raw_links < <(jq -r '.managed_links[]' <<<"$DS_MANIFEST_JSON")
for raw in "${raw_links[@]}"; do
  managed_links+=("$(expand_host_path "$raw")")
done

restore_paths=()
restore_modes=()
restore_backups=()
while IFS=$'\t' read -r raw mode; do
  [[ -n $raw ]] || continue
  path=$(expand_host_path "$raw")
  [[ $mode =~ ^[0-7]{3,4}$ ]] || die "invalid mode of the force-linked file $raw: $mode"
  restore_paths+=("$path")
  restore_modes+=("$mode")
  restore_backups+=("$(backup_copy_of "$path" || true)")
done < <(jq -r '.force_linked_restore[] | [.path, .mode] | @tsv' <<<"$DS_MANIFEST_JSON")

if ((dry_run)); then
  if ((recorded_previous)) && [[ $previous_generation == ABSENT ]]; then
    hm_action=remove-links
  elif ((recorded_previous)); then
    hm_action=activate-previous
  else
    hm_action=none
  fi

  if ((json)); then
    links_json='[]'
    if [[ $hm_action == remove-links ]] && ((${#managed_links[@]})); then
      links_json=$(printf '%s\n' "${managed_links[@]}" | jq -R . | jq -cs .)
    fi
    files_json='[]'
    if ((${#restore_paths[@]})); then
      files_json=$(for i in "${!restore_paths[@]}"; do
        jq -cn --arg path "${restore_paths[i]}" --arg mode "${restore_modes[i]}" \
          --arg backup "${restore_backups[i]}" \
          '{ path: $path, mode: $mode, backup: (if $backup == "" then null else $backup end) }'
      done | jq -cs .)
    fi
    jq -n \
      --arg manifest "$DS_MANIFEST_FILE" \
      --arg previous "$previous_generation" \
      --argjson recorded "$recorded_previous" \
      --arg user "$USER" \
      --argjson managed "$login_shell_managed" \
      --arg default_shell "$default_shell" \
      --arg shells_file "$shells_file" \
      --arg shells_line "$shells_line" \
      --arg hm_action "$hm_action" \
      --argjson links "$links_json" \
      --argjson files "$files_json" '
      def nullable: if . == "" then null else . end;
      {
        schema_version: 1,
        manifest: $manifest,
        previous_generation: (if $recorded == 1 then $previous else null end),
        steps: [
          { id: "login-shell", action: (if $managed == 1 then "set" else "keep" end), user: $user,
            shell: (if $managed == 1 then $default_shell else null end) },
          { id: "shells-line", action: (if $shells_line == "" then "none" else "remove" end),
            file: $shells_file, path: ($shells_line | nullable) },
          { id: "home-manager", action: $hm_action,
            generation: (if $hm_action == "activate-previous" then $previous else null end),
            links: $links },
          { id: "restore", files: $files },
          { id: "keep-settings" },
          { id: "keep-packages" }
        ]
      }'
    exit 0
  fi

  if ((login_shell_managed)); then
    printf '1. Set the login shell of %s to %s\n' "$USER" "$default_shell"
  else
    printf '1. Leave the login shell of %s unchanged (the instance does not manage it)\n' "$USER"
  fi
  if [[ -n $shells_line ]]; then
    printf '2. Remove the login shell line this system added to %s: %s\n' "$shells_file" "$shells_line"
  else
    printf '2. No login shell line added by this system to remove\n'
  fi
  case $hm_action in
    remove-links)
      printf '3. Remove the %s managed Nix links (there was no Home Manager before the first install)\n' \
        "${#managed_links[@]}"
      ;;
    activate-previous)
      printf '3. Activate the recorded previous Home Manager generation: %s\n' "$previous_generation"
      ;;
    none)
      printf '3. No previous Home Manager state is recorded; --apply refuses until rebuild --switch has run\n'
      ;;
  esac
  if ((${#restore_paths[@]})); then
    joined=$(printf '%s, ' "${restore_paths[@]}")
    printf '4. Restore the backed-up force-linked files with their modes: %s\n' "${joined%, }"
  else
    printf '4. No force-linked files to restore\n'
  fi
  printf '%s\n' \
    '5. Settings files synced by local-maintained-files stay in place as user data' \
    '6. Nix, the packages and user data stay installed'
  for i in "${!restore_paths[@]}"; do
    printf 'Backup of %s: %s\n' "${restore_paths[i]}" "${restore_backups[i]:-none; the restore is skipped}"
  done
  exit 0
fi

# --- Checks before the first change ---------------------------------------

((recorded_previous)) ||
  die "no previous Home Manager state is recorded: $previous_generation_file (run rebuild --switch first)"
if [[ $previous_generation == ABSENT ]]; then
  for path in "${managed_links[@]}"; do
    if [[ -L $path ]]; then
      target=$(readlink -f -- "$path") || die "cannot resolve the managed link: $path"
      [[ $target == "$store_dir"/* ]] || die "managed link points outside the Nix store: $path -> $target"
    elif [[ -e $path ]]; then
      die "rollback will not overwrite a user file: $path"
    fi
  done
else
  [[ -x $previous_generation/activate ]] ||
    die "the previous Home Manager generation is not valid: $previous_generation"
fi
if ((login_shell_managed)); then
  for function in platform_login_shell platform_set_login_shell; do
    declare -F "$function" >/dev/null || die "login shell changes are not available on $DS_RUNTIME_PLATFORM"
  done
fi

# --- Rollback -------------------------------------------------------------

if ((login_shell_managed)); then
  current_shell=$(platform_login_shell "$USER")
  if [[ $current_shell != "$default_shell" ]]; then
    log "setting the login shell to $default_shell"
    platform_set_login_shell "$default_shell" "$USER"
  fi
fi

if [[ -n $shells_line ]]; then
  log "removing the login shell line this system added to $shells_file: $shells_line"
  platform_shells_remove "$shells_line"
fi

if [[ $previous_generation == ABSENT ]]; then
  for path in "${managed_links[@]}"; do
    if [[ -L $path && $(readlink -f -- "$path") == "$store_dir"/* ]]; then
      rm -f -- "$path"
      log "removed the managed link: $path"
    fi
  done
else
  log "activating the previous Home Manager generation: $previous_generation"
  "$previous_generation/activate"
fi

for i in "${!restore_paths[@]}"; do
  path=${restore_paths[i]}
  backup=${restore_backups[i]}
  if [[ -z $backup ]]; then
    warn "no backup of $path; it did not exist before the first install, the restore is skipped"
    continue
  fi
  mkdir -p -- "$(dirname -- "$path")"
  if [[ -L $path || -f $path ]]; then
    rm -f -- "$path"
  fi
  install -m "${restore_modes[i]}" -- "$backup" "$path"
  log "restored $path from $backup"
done

log "rollback finished; Nix and the packages stay installed"
