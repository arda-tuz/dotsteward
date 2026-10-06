#!/usr/bin/env bash
# summary: run the system-install phase (deb transaction, phase hooks) or check every install method
#
# Port of the fresh-machine system package installer. In a fresh-mode
# profile `install` runs the preflight gate, then one deb transaction for
# the active deb components, then their systemInstall, postInstall and
# forbid hooks. In an adopt-mode profile it skips the phase with one log
# line before any other step (D14). --check-only checks every active
# component by its method instead (system-level methods are not-managed in
# adopt mode) and runs only the forbid hooks.
set -Eeuo pipefail

# shellcheck source=cli/lib/lib.sh
source "$DOTSTEWARD_LIB/lib.sh"
# shellcheck source=cli/lib/config.sh
source "$DOTSTEWARD_LIB/config.sh"
# shellcheck source=cli/lib/methods.sh
source "$DOTSTEWARD_LIB/methods.sh"

usage() {
  cat <<'EOF'
Usage: dotsteward install --profile PROFILE [--check-only] [--json] [--generation PATH]

Runs the system-install phase of PROFILE: in fresh mode the preflight gate,
one apt transaction for the deb components (DEBs below their floor are
downloaded and verified first; -y only with DOTSTEWARD_ASSUME_YES=1), the
floors verified afterwards, then the systemInstall, postInstall and forbid
hooks. In adopt mode the phase is skipped.

  --profile PROFILE   a profile of the instance (required)
  --check-only        check every active component by its method, run only
                      the forbid hooks; no change, no preflight
  --json              print the report as one JSON document on standard
                      output; logs go to standard error
  --generation PATH   read the manifest of a built generation (its hook
                      scripts are store paths) instead of the instance's
                      .dotsteward/manifest.<system>.json mirror

Exit status: 0 done or satisfied, 1 refusal or failed check, the
preflight's status (3: adaptive route) when it stops the phase.
EOF
}

profile=''
check_only=0
json=0
generation=''
while (($#)); do
  case $1 in
    --profile)
      (($# >= 2)) || die "install: --profile requires a value"
      profile=$2
      shift 2
      ;;
    --profile=*)
      profile=${1#--profile=}
      shift
      ;;
    --check-only)
      check_only=1
      shift
      ;;
    --json)
      json=1
      shift
      ;;
    --generation)
      (($# >= 2)) || die "install: --generation requires a value"
      generation=$2
      shift 2
      ;;
    --generation=*)
      generation=${1#--generation=}
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "install: unknown option: $1" ;;
  esac
done
[[ -n $profile ]] || die "install: --profile is required"

# shellcheck disable=SC2119 # the instance comes from --instance or discovery
config_load
require_profile "$profile"
mode=${DS_PROFILE_MODE[$profile]}
methods_manifest_load "$generation"

# With --json, everything but the report goes to standard error.
if ((json)); then
  exec 3>&1 1>&2
fi

# The lists are read into variables first, so a failure stops the command.
active_text=$(methods_components "$profile")
mapfile -t components < <(grep -v '^$' <<<"$active_text" || true)
report_components=()
report_hooks=()
result=passed

# report NAME METHOD STATUS DETAIL: one component's line (human output) and
# report entry.
report() {
  if ((!json)); then
    log "$1 ($2): $3: $4"
  fi
  report_components+=("$(jq -cn --arg name "$1" --arg method "$2" --arg status "$3" --arg detail "$4" \
    '{ name: $name, method: $method, status: $status, detail: $detail }')")
}

# failure NAME METHOD DETAIL: a failed check: fatal without --json,
# recorded with it.
failure() {
  if ((!json)); then
    die "$1 ($2): $3"
  fi
  printf '[dotsteward] ERROR: %s (%s): %s\n' "$1" "$2" "$3" >&2
  report "$1" "$2" failed "$3"
  result=failed
}

# run_hooks LIST CHECK_ONLY: runs the hooks of LIST; a failing hook is fatal
# without --json in check-only mode and always outside it.
run_hooks() {
  local list=$1 hook_check_only=$2 hook hooks_text status component name
  local -a hooks=()
  hooks_text=$(methods_hooks "$list" "$profile")
  mapfile -t hooks < <(grep -v '^$' <<<"$hooks_text" || true)
  for hook in "${hooks[@]}"; do
    component=$(jq -r '.component' <<<"$hook")
    name=$(jq -r '.name' <<<"$hook")
    status=0
    methods_run_hook "$hook" "$profile" "$hook_check_only" || status=$?
    report_hooks+=("$(jq -cn --arg component "$component" --arg name "$name" --arg list "$list" \
      --argjson status "$status" \
      '{ component: $component, name: $name, list: $list,
         status: (if $status == 0 then "passed" else "failed" end), exit_code: $status }')")
    if ((status != 0)); then
      if ((json && hook_check_only)); then
        printf '[dotsteward] ERROR: component %s hook %s failed (exit %s)\n' "$component" "$name" "$status" >&2
        result=failed
      else
        die "component $component hook $name failed (exit $status)"
      fi
    fi
  done
}

# validate_hooks LIST...: every hook script of the lists resolves before
# anything runs.
validate_hooks() {
  local list hook hooks_text
  local -a hooks=()
  for list in "$@"; do
    hooks_text=$(methods_hooks "$list" "$profile")
    mapfile -t hooks < <(grep -v '^$' <<<"$hooks_text" || true)
    for hook in "${hooks[@]}"; do
      methods_hook_path "$hook" >/dev/null
    done
  done
}

emit_report() {
  if ((json)); then
    jq -n --arg profile "$profile" --arg mode "$mode" --argjson check_only "$check_only" \
      --arg result "$result" \
      --argjson components "$(printf '%s\n' "${report_components[@]}" | jq -cs .)" \
      --argjson hooks "$(printf '%s\n' "${report_hooks[@]}" | jq -cs .)" \
      '{ schema_version: 1, profile: $profile, mode: $mode, check_only: ($check_only == 1),
         result: $result, components: $components, hooks: $hooks }' >&3
  fi
  [[ $result == passed ]]
}

# What `install` leaves to other parts of dotsteward.
delegated_detail() {
  case $1 in
    nix) printf 'installed by Home Manager\n' ;;
    official-binary) printf 'installed by dotsteward agents install\n' ;;
    external) printf 'not installed by dotsteward\n' ;;
  esac
}

# --- adopt mode: one line, nothing else -----------------------------------
if [[ $mode == adopt && $check_only == 0 ]]; then
  skipped=()
  for name in "${components[@]}"; do
    method=$(methods_component_method "$name")
    if methods_is_system_level "$method"; then
      skipped+=("$name")
      report_components+=("$(jq -cn --arg name "$name" --arg method "$method" \
        '{ name: $name, method: $method, status: "not-managed", detail: "system-level method in adopt mode" }')")
    else
      report_components+=("$(jq -cn --arg name "$name" --arg method "$method" --arg detail "$(delegated_detail "$method")" \
        '{ name: $name, method: $method, status: "skipped", detail: $detail }')")
    fi
  done
  if ((${#skipped[@]})); then
    joined=$(printf '%s, ' "${skipped[@]}")
    log "$profile (adopt mode): system install skipped; not managed: ${joined%, }"
  else
    log "$profile (adopt mode): system install skipped"
  fi
  emit_report
  exit 0
fi

# --- check-only -----------------------------------------------------------
if ((check_only)); then
  for name in "${components[@]}"; do
    method=$(methods_component_method "$name")
    status=0
    methods_check "$name" "$profile" || status=$?
    if ((status != 0)); then
      failure "$name" "$method" "$METHODS_DETAIL"
    else
      report "$name" "$method" "$METHODS_STATUS" "$METHODS_DETAIL"
    fi
  done
  if [[ $mode == fresh ]]; then
    validate_hooks forbid
    run_hooks forbid 1
  fi
  emit_report || exit 1
  exit 0
fi

# --- fresh mode -----------------------------------------------------------
for name in "${components[@]}"; do
  methods_validate "$name"
done
validate_hooks system_install post_install forbid

status=0
"$DOTSTEWARD_FRAMEWORK_ROOT/cli/dotsteward" --instance "$DS_INSTANCE_ROOT" \
  preflight --read-only --json --profile "$profile" >/dev/null || status=$?
((status == 0)) || exit "$status"

deb_components=()
for name in "${components[@]}"; do
  [[ $(methods_component_method "$name") == deb ]] && deb_components+=("$name")
done
methods_deb_transaction "${deb_components[@]}"

for name in "${components[@]}"; do
  method=$(methods_component_method "$name")
  case $method in
    deb) report "$name" "$method" "${METHODS_DEB_STATUS[$name]}" "${METHODS_DEB_DETAIL[$name]}" ;;
    app-archive)
      platform_app_archive_install "$name"
      report "$name" "$method" "$METHODS_STATUS" "$METHODS_DETAIL"
      ;;
    *) report "$name" "$method" skipped "$(delegated_detail "$method")" ;;
  esac
done

run_hooks system_install 0
run_hooks post_install 0
run_hooks forbid 0
log "system install verified for profile $profile"
emit_report
