#!/usr/bin/env bash
# summary: Run a component hook with the hook environment
#
# `dotsteward component run NAME HOOK [-- ARG...]` (SPEC 6.2, 8.4) runs one
# hook of component NAME, the way the framework runs it in a phase, with
# the given arguments: an instance wrapper script stays a one-liner
# (`dotsteward component run <name> <hook> -- "$@"`). The hook is found by
# name in every hook list of the manifest (hooks.*, checks.e2e,
# checks.agents); a name that resolves to different scripts in several
# lists is ambiguous. It runs with the hook environment (cli/lib/methods.sh
# methods_run_hook) and DOTSTEWARD_CHECK_ONLY=0; the hook's own arguments
# decide what it does. The exit status is the hook's.
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
Usage: dotsteward component run NAME HOOK [--profile PROFILE]
                                [--generation PATH] [-- ARG...]

Runs hook HOOK of component NAME with the hook environment and the
arguments after --. The hook is looked up in every hook list of the
manifest (hooks.*, checks.e2e, checks.agents).

  --profile PROFILE   DOTSTEWARD_PROFILE of the hook; default: the current
                      profile recorded by the last rebuild, else
                      profiles.check
  --generation PATH   a built Home Manager generation whose manifest (and
                      hook scripts) to use; default: the active generation,
                      else the instance's manifest mirror

The component must be enabled and active in the profile.

Exit status: the hook's; 1 for a refusal.
EOF
}

subcommand=''
profile=''
generation=''
positional=()
hook_args=()
while (($#)); do
  case $1 in
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      hook_args=("$@")
      break
      ;;
    --profile | --generation)
      if (($# < 2)) || [[ -z $2 ]]; then
        die "component ${subcommand:+$subcommand: }$1 requires a value"
      fi
      if [[ $1 == --profile ]]; then
        profile=$2
      else
        generation=$2
      fi
      shift 2
      ;;
    --profile=*)
      profile=${1#--profile=}
      [[ -n $profile ]] || die "component: --profile requires a value"
      shift
      ;;
    --generation=*)
      generation=${1#--generation=}
      [[ -n $generation ]] || die "component: --generation requires a value"
      shift
      ;;
    -*)
      die "component${subcommand:+ $subcommand}: unknown option: $1"
      ;;
    *)
      if [[ -z $subcommand ]]; then
        [[ $1 == run ]] || die "component: unknown subcommand: $1"
        subcommand=$1
      else
        positional+=("$1")
      fi
      shift
      ;;
  esac
done
[[ -n $subcommand ]] || die "component: run is required"
((${#positional[@]} >= 2)) || die "component run: NAME and HOOK are required"
((${#positional[@]} == 2)) ||
  die "component run: unexpected argument: ${positional[2]} (pass hook arguments after --)"
name=${positional[0]}
hook_name=${positional[1]}
if [[ -n $generation ]]; then
  [[ -d $generation ]] || die "component run: generation not found: $generation"
  generation=$(cd -P -- "$generation" && pwd)
fi

# shellcheck disable=SC2119 # the instance comes from --instance or discovery
config_load
if [[ -z $profile ]]; then
  current_file=$(state_root)/current/profile
  if [[ -f $current_file ]]; then
    profile=$(<"$current_file")
    profile=${profile%%[[:space:]]*}
  fi
  [[ -n $profile ]] || profile=$DS_PROFILES_CHECK
fi
require_profile "$profile"
require_safe_identity
for tool in jq realpath; do
  require_command "$tool"
done

if [[ -z $generation ]]; then
  generation=$(skills_active_generation)
fi
methods_manifest_load "$generation"

jq -e --arg name "$name" 'any(.components[]; .name == $name)' <<<"$DS_MANIFEST_JSON" >/dev/null ||
  die "component run: component $name is not enabled in this instance"
active_text=$(methods_components "$profile")
grep -Fxq -- "$name" <<<"$active_text" ||
  die "component run: component $name is not active in profile $profile"

matches=$(jq -c --arg component "$name" --arg hook "$hook_name" '
  [ ((.hooks // {}) | to_entries[] | .key as $list | .value[] | . + { list: ("hooks." + $list) }),
    ((.checks.e2e // [])[] | . + { list: "checks.e2e" }),
    ((.checks.agents // [])[] | . + { list: "checks.agents" }) ]
  | map(select(.component == $component and .name == $hook))' <<<"$DS_MANIFEST_JSON")
count=$(jq 'length' <<<"$matches")
((count > 0)) || die "component run: component $name has no hook $hook_name"
if (($(jq '[.[].script] | unique | length' <<<"$matches") > 1)); then
  lists=$(jq -r '[.[].list] | unique | join(", ")' <<<"$matches")
  die "component run: hook $hook_name of component $name is ambiguous ($lists)"
fi
hook=$(jq -c '.[0]' <<<"$matches")
methods_hook_path "$hook" >/dev/null

status=0
methods_run_hook "$hook" "$profile" 0 "${hook_args[@]}" || status=$?
if ((status != 0)); then
  printf '[dotsteward] ERROR: component %s hook %s failed (exit %s)\n' "$name" "$hook_name" "$status" >&2
fi
exit "$status"
