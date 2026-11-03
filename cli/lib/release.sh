# shellcheck shell=bash
# The release rules of the framework, shared by `dotsteward contribute`
# (publish and release, cli/lib/contribute-remote.sh) and tools/version.sh
# (the release commit and the release workflow): release trains with
# semantic versions from conventional commits, grouped release notes, and
# main's CI of a commit. Needs bash 4.4, git, jq and the coreutils; gh for
# main's CI only.
#
# A release is a stable tag vX.Y.Z (no leading zeros) on a commit whose
# VERSION is X.Y.Z. Between two releases VERSION stays at the release the
# commits are based on; a release commit (tools/version.sh bump) sets it to
# the next version, after the newest release, as the commits since the base
# release decide:
#   a breaking change (type! or a BREAKING CHANGE footer)  the next major,
#                                                          only when asked
#                                                          for: a major is
#                                                          never cut by
#                                                          accident
#   any feat                                               the next minor
#   anything else                                          the next patch
#
#   release_is_version TEXT     TEXT is X.Y.Z
#   release_local_tags DIR      the stable release tags of the clone DIR as
#                               "TAG COMMIT" lines
#   release_kind DIR BASE REV   breaking, feat, fix or none: the largest
#                               change of the commits BASE..REV (every
#                               commit of REV when BASE is empty), merges
#                               skipped
#   release_next VERSION KIND MAJOR(0|1)
#                               the version after VERSION for KIND; status
#                               2 for none (nothing to release), 3 for a
#                               breaking change without MAJOR=1
#   release_state DIR REV TAGS  the release state of commit REV (below)
#   release_base_before DIR REV TAG TAGS
#                               the commit of the newest release of TAGS
#                               below TAG that REV contains (nothing when
#                               none): where the notes of TAG start
#   release_notes DIR BASE REV  the release notes of BASE..REV in Markdown:
#                               the commit subjects, oldest first, under
#                               Features (feat), Fixes (fix) and Other
#   release_main_ci REPO SHA WORKFLOW...
#                               main's CI of SHA on GitHub (below)

# A conventional subject: type, optional (scope), optional !, ": ", text.
RELEASE_SUBJECT='^([a-z]+)(\(([^)]*)\))?(!)?: (.+)$'
# A breaking change footer.
RELEASE_BREAKING='(^|'$'\n'')BREAKING[ -]CHANGE: '

release_is_version() {
  [[ $1 =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

release_local_tags() {
  local name
  while IFS= read -r name; do
    release_is_version "${name#v}" || continue
    printf '%s %s\n' "$name" "$(git -C "$1" rev-parse "refs/tags/$name^{commit}")"
  done < <(git -C "$1" tag --list 'v*')
}

# _release_sorted TAGS: the "TAG COMMIT" lines of stable tags, newest version
# first, one line per tag.
_release_sorted() {
  local tag commit
  local -A seen=()
  while read -r tag commit; do
    [[ -n ${tag:-} && -z ${seen[$tag]:-} ]] || continue
    release_is_version "${tag#v}" || continue
    seen[$tag]=1
    printf '%s %s\n' "$tag" "$commit"
  done <<<"$1" | sort -r -V -k1,1
}

# _release_log DIR BASE REV: the commits BASE..REV (every commit of REV
# without BASE), merges skipped, as "short<US>subject<US>body<RS>" records,
# oldest first.
_release_log() {
  local range=$3
  [[ -z $2 ]] || range=$2..$3
  git -C "$1" log --reverse --no-merges --format='%h%x1f%s%x1f%b%x1e' "$range"
}

release_kind() {
  local dir=$1 base=$2 rev=$3 kind=none record subject body
  while IFS= read -r -d $'\x1e' record; do
    record=${record#$'\n'}
    [[ -n $record ]] || continue
    subject=${record#*$'\x1f'}
    body=${subject#*$'\x1f'}
    subject=${subject%%$'\x1f'*}
    if [[ $subject =~ $RELEASE_SUBJECT && -n ${BASH_REMATCH[4]} ]] || [[ $body =~ $RELEASE_BREAKING ]]; then
      kind=breaking
      break
    fi
    if [[ $subject =~ $RELEASE_SUBJECT && ${BASH_REMATCH[1]} == feat ]]; then
      kind=feat
    elif [[ $kind == none ]]; then
      kind=fix
    fi
  done < <(_release_log "$dir" "$base" "$rev")
  printf '%s\n' "$kind"
}

release_next() {
  local version=$1 kind=$2 major=$3 x y z
  release_is_version "$version" || return 1
  IFS=. read -r x y z <<<"$version"
  case $kind in
    none) return 2 ;;
    breaking) ((major)) || return 3 ;;
  esac
  if ((major)); then
    printf '%s.0.0\n' "$((x + 1))"
  elif [[ $kind == feat ]]; then
    printf '%s.%s.0\n' "$x" "$((y + 1))"
  else
    printf '%s.%s.%s\n' "$x" "$y" "$((z + 1))"
  fi
}

# release_state DIR REV TAGS: the release state of commit REV of the clone
# DIR. TAGS are "TAG COMMIT" lines of the release tags (the clone's, or its
# remotes' from ls-remote, peeled); NEWEST is the newest of them, BASE the
# newest whose commit REV contains (0.0.0 without one). One line "STATE
# VERSION BASE NEXT MAJOR KIND BASE_COMMIT":
#   none      VERSION (at REV) is BASE's: no release pending
#   pending   VERSION is NEXT, the release after NEWEST for KIND, the
#             largest change since BASE: a release is pending
#   mismatch  VERSION is neither; NEXT is what a release would be ("-" for a
#             breaking change while VERSION asks for no major)
# MAJOR is 1 when VERSION asks for a major release (its major number is
# above NEWEST's); BASE_COMMIT is "-" without BASE. Status 1 when VERSION is
# missing at REV or not X.Y.Z.
release_state() {
  local dir=$1 rev=$2 version newest="" base="" base_commit="" tag commit kind next major=0 sorted
  version=$(git -C "$dir" show "$rev:VERSION" 2>/dev/null) || return 1
  version=${version//[[:space:]]/}
  release_is_version "$version" || return 1
  sorted=$(_release_sorted "$3")
  while read -r tag commit; do
    [[ -n ${tag:-} ]] || continue
    [[ -n $newest ]] || newest=${tag#v}
    if git -C "$dir" merge-base --is-ancestor "$commit" "$rev" 2>/dev/null; then
      base=${tag#v}
      base_commit=$commit
      break
    fi
  done <<<"$sorted"
  [[ -n $newest ]] || newest=0.0.0
  [[ -n $base ]] || base=0.0.0
  kind=$(release_kind "$dir" "$base_commit" "$rev")
  ((${version%%.*} <= ${newest%%.*})) || major=1
  next=$(release_next "$newest" "$kind" "$major") || next=-
  if [[ $version == "$base" ]]; then
    printf 'none'
  elif [[ $version == "$next" ]]; then
    printf 'pending'
  else
    printf 'mismatch'
  fi
  printf ' %s %s %s %s %s %s\n' "$version" "$base" "$next" "$major" "$kind" "${base_commit:--}"
}

release_base_before() {
  local dir=$1 rev=$2 tag=$3 name commit
  while read -r name commit; do
    [[ -n ${name:-} && $name != "$tag" ]] || continue
    [[ $(printf '%s\n%s\n' "$name" "$tag" | sort -V | head -n 1) == "$name" ]] || continue
    if git -C "$dir" merge-base --is-ancestor "$commit" "$rev" 2>/dev/null; then
      printf '%s\n' "$commit"
      return 0
    fi
  done < <(_release_sorted "$4")
}

release_notes() {
  local dir=$1 base=$2 rev=$3 record short subject body type scope text line out=""
  local features="" fixes="" other=""
  while IFS= read -r -d $'\x1e' record; do
    record=${record#$'\n'}
    [[ -n $record ]] || continue
    short=${record%%$'\x1f'*}
    subject=${record#*$'\x1f'}
    body=${subject#*$'\x1f'}
    subject=${subject%%$'\x1f'*}
    type="" scope="" text=$subject line="- "
    if [[ $subject =~ $RELEASE_SUBJECT ]]; then
      type=${BASH_REMATCH[1]}
      scope=${BASH_REMATCH[3]}
      text=${BASH_REMATCH[5]}
      [[ -z ${BASH_REMATCH[4]} ]] || line+="Breaking: "
    fi
    if [[ $line != *Breaking* && $body =~ $RELEASE_BREAKING ]]; then
      line+="Breaking: "
    fi
    [[ -z $scope ]] || line+="$scope: "
    line+="$text ($short)"$'\n'
    case $type in
      feat) features+=$line ;;
      fix) fixes+=$line ;;
      *) other+=$line ;;
    esac
  done < <(_release_log "$dir" "$base" "$rev")
  [[ -z $features ]] || out+="## Features"$'\n\n'"$features"$'\n'
  [[ -z $fixes ]] || out+="## Fixes"$'\n\n'"$fixes"$'\n'
  [[ -z $other ]] || out+="## Other"$'\n\n'"$other"$'\n'
  if [[ -z $out ]]; then
    printf 'No changes.\n'
  else
    printf '%s' "${out%$'\n'}"
  fi
}

# release_main_ci REPO SHA WORKFLOW...: main's CI of commit SHA in the GitHub
# repository REPO, read once: the newest push run on main of every WORKFLOW
# (a file name), as one JSON object {sha, state, url, runs: [{workflow, id,
# status, conclusion, url}]}. A run's status is missing while it has none;
# state is red when a run concluded with anything but success, skipped or
# neutral, pending while one is missing or not completed, else green; url is
# the first red run's, else the first WORKFLOW's. Status 1 when gh cannot
# list the runs.
release_main_ci() {
  local repo=$1 sha=$2 answer
  shift 2
  answer=$(gh api -X GET "repos/$repo/actions/runs" -f head_sha="$sha" -f event=push -f branch=main \
    -F per_page=100 </dev/null) || return 1
  jq -c --arg sha "$sha" --args '
    def green: . == "success" or . == "skipped" or . == "neutral";
    [.workflow_runs[]? | select(.event == "push" and .head_branch == "main" and .head_sha == $sha)] as $all
    | [$ARGS.positional[] as $workflow
        | ([$all[] | select(((.path // "") | split("@")[0]) == ".github/workflows/" + $workflow)]
           | sort_by(.created_at, .id) | last) as $run
        | if $run == null then {workflow: $workflow, id: null, status: "missing", conclusion: null, url: null}
          else {workflow: $workflow, id: $run.id, status: $run.status, conclusion: $run.conclusion,
                url: $run.html_url} end] as $runs
    | ($runs | map(select(.status == "completed" and ((.conclusion // "") | green | not)))) as $red
    | {sha: $sha,
       state: (if ($red | length) > 0 then "red"
               elif ($runs | all(.status == "completed")) then "green" else "pending" end),
       url: (if ($red | length) > 0 then $red[0].url else $runs[0].url end),
       runs: $runs}' "$@" <<<"$answer"
}
