#!/usr/bin/env bash
# summary: Scan files, the staged index or a commit range for secrets and private data
#
# Usage: dotsteward scan (--tree | --staged | --range RANGE) [OPTION...]
#
# Modes (exactly one):
#   --tree           git-visible files of the work tree (tracked and untracked,
#                    not ignored); outside git every file below the current
#                    directory except .git directories
#   --staged         index blobs of the paths staged for the next commit
#   --range RANGE    every commit of RANGE (A..B, B, ^A, several separated by
#                    spaces): the blobs each commit changed, its message and
#                    identities, and annotated tags pointing into the range
# Options:
#   --metadata          also apply the commit rules (e-mail, UTC dates,
#                       forbidden message lines); --range only
#   --denylist F        private terms (plain, word:TERM, re:ERE; # comments)
#   --require-denylist  refuse to run without a denylist; without --denylist
#                       the policy's denylist path is used
#   --extra-terms F     more terms in the denylist format
#   --redact            print rule and location only, never the matched text
#
# The policy is privacy/policy.toml of the scanned repository root when it
# exists, otherwise the framework's own; privacy/allowlist.txt next to it
# lists public strings that are masked before term matching. Exit 0 when
# clean, 1 on any finding (after collecting all of them) or error.
set -Eeuo pipefail

# The pre-push hook runs this file directly, without the dispatcher, so the
# framework root comes from this file's location.

framework_root=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

error() {
  printf '[dotsteward] ERROR: %s\n' "$*" >&2
}

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  error "scan needs bash 4.4 or newer (found $BASH_VERSION)"
  exit 1
fi

# shellcheck source=cli/lib/privacy.sh
source "$framework_root/cli/lib/privacy.sh"

# Errors the library reports itself end the scan with their own message; any
# other failure is reported here instead of ending the scan silently.
trap 'status=$?; [[ -n ${DS_PRIVACY_ERRORED:-} ]] || error "scan failed unexpectedly at line $LINENO (exit $status)"' ERR

usage() {
  sed -n '4,/^set -Eeuo pipefail$/{/^set /d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"
}

modes=0
mode=""
range=""
denylist=""
extra_terms=""
require_denylist=0
metadata=0
redact=0

# need_value FLAG ARGC VALUE: fails unless an option that takes a value got one.
need_value() {
  if (($2 < 2)) || [[ -z $3 ]]; then
    error "$1 requires a value"
    exit 1
  fi
}

while (($#)); do
  case $1 in
    -h | --help)
      usage
      exit 0
      ;;
    --tree | --staged)
      mode=${1#--}
      modes=$((modes + 1))
      shift
      ;;
    --range | --denylist | --extra-terms)
      need_value "$1" "$#" "${2:-}"
      case $1 in
        --range)
          mode=range
          modes=$((modes + 1))
          range=$2
          ;;
        --denylist) denylist=$2 ;;
        --extra-terms) extra_terms=$2 ;;
      esac
      shift 2
      ;;
    --range=* | --denylist=* | --extra-terms=*)
      need_value "${1%%=*}" 2 "${1#*=}"
      case $1 in
        --range=*)
          mode=range
          modes=$((modes + 1))
          range=${1#*=}
          ;;
        --denylist=*) denylist=${1#*=} ;;
        --extra-terms=*) extra_terms=${1#*=} ;;
      esac
      shift
      ;;
    --require-denylist)
      require_denylist=1
      shift
      ;;
    --metadata)
      metadata=1
      shift
      ;;
    --redact)
      redact=1
      shift
      ;;
    -*)
      error "unknown option: $1"
      exit 1
      ;;
    *)
      error "unexpected argument: $1"
      exit 1
      ;;
  esac
done

if ((modes != 1)); then
  error "choose exactly one of --tree, --staged or --range"
  exit 1
fi
if ((metadata)) && [[ $mode != range ]]; then
  error "--metadata requires --range"
  exit 1
fi

# The scan root: the work tree root inside git, the current directory
# otherwise; a range scan only needs a repository.
in_work_tree=0
if [[ $(git rev-parse --is-inside-work-tree 2>/dev/null || true) == true ]]; then
  in_work_tree=1
  root=$(git rev-parse --show-toplevel)
else
  root=$(pwd -P)
fi
case $mode in
  staged)
    ((in_work_tree)) || {
      error "--staged requires a git work tree"
      exit 1
    }
    ;;
  range)
    git rev-parse --git-dir >/dev/null 2>&1 || {
      error "--range requires a git repository"
      exit 1
    }
    ;;
esac

policy_dir=$framework_root/privacy
if [[ -f $root/privacy/policy.toml ]]; then
  policy_dir=$root/privacy
fi
ds_privacy_load_policy "$policy_dir/policy.toml"
ds_privacy_load_allowlist "$policy_dir/allowlist.txt"

# load_terms KIND SHOWN FILE: SHOWN is the path as the user gave it.
load_terms() {
  local kind=$1 shown=$2 file=$3
  if [[ ! -f $file || ! -r $file ]]; then
    error "$kind file is missing or unreadable: $shown"
    exit 1
  fi
  ds_privacy_load_terms "$kind" "$file"
}

denylist_shown=$denylist
if [[ -z $denylist && $require_denylist == 1 ]]; then
  denylist_shown=$DS_PRIVACY_DENYLIST_PATH
  denylist=$DS_PRIVACY_DENYLIST_PATH
  # shellcheck disable=SC2088 # a literal tilde from the policy, expanded here
  [[ $denylist != "~/"* ]] || denylist=$HOME/${denylist#"~/"}
fi
if [[ -n $denylist ]]; then
  load_terms denylist "$denylist_shown" "$denylist"
  if ((require_denylist && DS_PRIVACY_TERMS_LOADED == 0)); then
    error "denylist has no entries: $denylist_shown"
    exit 1
  fi
fi
if [[ -n $extra_terms ]]; then
  load_terms extra-terms "$extra_terms" "$extra_terms"
fi

trap ds_privacy_end EXIT
ds_privacy_begin
case $mode in
  tree) ds_privacy_collect_tree "$root" "$in_work_tree" ;;
  staged) ds_privacy_collect_staged "$root" ;;
  range) ds_privacy_collect_range "$PWD" "$range" ;;
esac
ds_privacy_report "$redact" "$metadata"

if ((DS_PRIVACY_FINDINGS == 0)); then
  printf '[dotsteward] scan clean: %s files, %s commits\n' "$DS_PRIVACY_FILES" "$DS_PRIVACY_COMMITS"
  exit 0
fi
noun=findings
((DS_PRIVACY_FINDINGS != 1)) || noun=finding
error "scan found $DS_PRIVACY_FINDINGS $noun in $DS_PRIVACY_FILES files, $DS_PRIVACY_COMMITS commits"
exit 1
