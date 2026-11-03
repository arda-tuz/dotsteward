#!/usr/bin/env bash
# The framework version: VERSION is its only hand-written copy. This tool
# writes the other copies, prepares the release commit and cuts a release
# (the release workflow, .github/workflows/release.yml), with the rules of
# cli/lib/release.sh.
#
# Usage: tools/version.sh sync [--check] [--root DIR]
#        tools/version.sh next [--major] [--root DIR] [REV]
#        tools/version.sh notes [--root DIR] [REV]
#        tools/version.sh bump [--major] [--commit] [--root DIR]
#        tools/version.sh release --repo OWNER/REPO [--rev REV] [--major] [--root DIR]
#
# DIR is the framework checkout (default: the one holding this script); its
# release tags are its local stable vX.Y.Z tags.
#
# sync     writes VERSION into its copies: every "version" key of the plugin
#          and marketplace manifests (.claude-plugin/marketplace.json,
#          .agents/plugins/marketplace.json and the plugin.json of both
#          channels in plugins/dotsteward) and the release tag of the
#          dotsteward input in template/flake.nix
#          (github:OWNER/dotsteward/vX.Y.Z). --check writes nothing, names
#          every stale copy on standard error and exits 1.
# next     the next release for REV (default HEAD): after the newest release
#          tag, as the commits since the newest release REV contains
#          decide; a breaking change needs --major (exit 3 without it).
#          Exit 2 when REV has nothing to release.
# notes    the release notes (Markdown: Features, Fixes, Other) of the
#          commits since the newest release REV contains.
# bump     the change of a release commit: VERSION set to `next` for HEAD,
#          then sync. --commit also commits exactly those files as the
#          release commit "chore(release): X.Y.Z" (with TZ=UTC and the
#          clone's identity); other changes stay out of it.
# release  cuts the pending release of REV (default HEAD) in the GitHub
#          repository OWNER/REPO, tag only (no commit). Nothing when VERSION
#          at REV is still the release it is based on; refused when VERSION
#          is not the next release, for a major release without --major,
#          when the tag exists elsewhere, and unless main's CI of REV (the
#          push runs of ci.yml and privacy.yml on main) is green. Then `gh
#          release create vX.Y.Z --target REV` with the notes, and
#          channels.yml and macos-smoke.yml dispatched on the tag (a tag
#          made with a workflow's token starts no workflow). A GitHub
#          release of the tag that `dotsteward contribute release` created
#          meanwhile is the release when its tag names REV (done, nothing
#          dispatched); on another commit it is refused.
#          RELEASE_WAIT_SECONDS (default 1800)
#          bounds the wait for main's CI, RELEASE_POLL_SECONDS (default 15)
#          is its polling interval.
#
# Exit status: 0 done (nothing pending included), 1 refused or failed, 2
# nothing to release (next), 3 a breaking change needs --major (next, bump).
set -Eeuo pipefail

script_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=cli/lib/release.sh
source "$script_root/cli/lib/release.sh"

# The JSON files whose "version" keys follow VERSION.
VERSION_JSON_COPIES=(
  .claude-plugin/marketplace.json
  .agents/plugins/marketplace.json
  plugins/dotsteward/.claude-plugin/plugin.json
  plugins/dotsteward/.codex-plugin/plugin.json
)
# The instance template, whose dotsteward input pins the release.
VERSION_TEMPLATE=template/flake.nix
# The workflows of main's CI.
VERSION_MAIN_CI=(ci.yml privacy.yml)

say() {
  printf '[version] %s\n' "$*"
}

die() {
  printf '[version] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '/^# Usage:/,/^#$/{/^#$/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"
}

# read_version DIR: VERSION of the checkout DIR.
read_version() {
  local text
  [[ -f $1/VERSION ]] || die "no VERSION in $1"
  text=$(<"$1/VERSION")
  release_is_version "$text" || die "VERSION is not one X.Y.Z line: $1/VERSION"
  printf '%s\n' "$text"
}

# rendered DIR FILE VERSION: FILE of DIR with VERSION in its copy.
rendered() {
  local dir=$1 file=$2 version=$3 count
  case $file in
    "$VERSION_TEMPLATE")
      count=$(grep -cE 'url = "github:[A-Za-z0-9_.-]+/dotsteward/v[0-9]+\.[0-9]+\.[0-9]+"' "$dir/$file" || true)
      [[ $count == 1 ]] || die "$file needs exactly one url = \"github:OWNER/dotsteward/vX.Y.Z\" line, found $count"
      sed -E "s|(url = \"github:[A-Za-z0-9_.-]+/dotsteward/)v[0-9]+\\.[0-9]+\\.[0-9]+\"|\\1v$version\"|" "$dir/$file"
      ;;
    *)
      jq --indent 2 --arg version "$version" '(.. | objects | select(has("version")) | .version) = $version' \
        "$dir/$file" || die "$file is not JSON"
      ;;
  esac
}

cmd_sync() {
  local root=$1 check=$2 version file tmp stale=0
  version=$(read_version "$root")
  for file in "${VERSION_JSON_COPIES[@]}" "$VERSION_TEMPLATE"; do
    [[ -f $root/$file ]] || die "missing $file"
    tmp=$(mktemp "$root/$file.XXXXXX")
    if ! rendered "$root" "$file" "$version" >"$tmp"; then
      rm -f -- "$tmp"
      exit 1
    fi
    if cmp -s -- "$tmp" "$root/$file"; then
      rm -f -- "$tmp"
    elif ((check)); then
      rm -f -- "$tmp"
      printf '[version] stale: %s does not carry VERSION %s\n' "$file" "$version" >&2
      stale=1
    else
      chmod 0644 "$tmp"
      mv -f -- "$tmp" "$root/$file"
      say "wrote $file ($version)"
    fi
  done
  if ((stale)); then
    printf '[version] ERROR: run tools/version.sh sync\n' >&2
    exit 1
  fi
}

# state ROOT REV: release_state of REV with the checkout's tags.
state() {
  local tags
  tags=$(release_local_tags "$1")
  release_state "$1" "$2" "$tags" || die "VERSION at $2 is missing or not X.Y.Z"
}

cmd_next() {
  local root=$1 major=$2 rev=$3 line fields status=0 newest
  line=$(state "$root" "$rev")
  read -ra fields <<<"$line"
  newest=$(release_local_tags "$root" | awk '{ print $1 }' | sed 's/^v//' | sort -r -V | head -n 1)
  release_next "${newest:-0.0.0}" "${fields[5]}" "$major" || status=$?
  case $status in
    0) ;;
    2)
      printf '[version] nothing to release: %s has no commit after v%s\n' "$rev" "${fields[2]}" >&2
      exit 2
      ;;
    3)
      printf '[version] ERROR: the commits since v%s hold a breaking change: the next release is a major one, which needs --major (a decision of the user)\n' "${fields[2]}" >&2
      exit 3
      ;;
    *) exit 1 ;;
  esac
}

cmd_notes() {
  local root=$1 rev=$2 line fields base=""
  line=$(state "$root" "$rev")
  read -ra fields <<<"$line"
  [[ ${fields[6]} == - ]] || base=${fields[6]}
  release_notes "$root" "$base" "$rev"
}

cmd_bump() {
  local root=$1 major=$2 commit=$3 old next
  old=$(read_version "$root")
  next=$(cmd_next "$root" "$major" HEAD)
  printf '%s\n' "$next" >"$root/VERSION"
  cmd_sync "$root" 0
  say "VERSION: $old -> $next"
  ((commit)) || return 0
  git -C "$root" add -- VERSION "${VERSION_JSON_COPIES[@]}" "$VERSION_TEMPLATE"
  TZ=UTC git -C "$root" commit --quiet -m "chore(release): $next" -- VERSION "${VERSION_JSON_COPIES[@]}" "$VERSION_TEMPLATE" ||
    die "cannot commit the release commit of $next"
  say "committed: chore(release): $next ($(git -C "$root" rev-parse --short=12 HEAD))"
}

# wait_main_ci REPO SHA: main's CI of SHA green, waited for while pending.
wait_main_ci() {
  local repo=$1 sha=$2 limit interval start document state
  limit=${RELEASE_WAIT_SECONDS:-1800}
  interval=${RELEASE_POLL_SECONDS:-15}
  [[ $limit =~ ^[1-9][0-9]*$ && $interval =~ ^[1-9][0-9]*$ ]] ||
    die "RELEASE_WAIT_SECONDS and RELEASE_POLL_SECONDS must be positive numbers of seconds"
  start=$SECONDS
  while :; do
    document=$(release_main_ci "$repo" "$sha" "${VERSION_MAIN_CI[@]}") || die "cannot list the CI runs of $sha in $repo"
    state=$(jq -r .state <<<"$document")
    case $state in
      green)
        say "main's CI is green on ${sha:0:12}"
        return 0
        ;;
      red) die "main's CI is red on ${sha:0:12}: $(jq -r .url <<<"$document"); nothing is released" ;;
    esac
    ((SECONDS - start < limit)) ||
      die "main's CI on ${sha:0:12} is not green within ${limit}s ($(jq -r '[.runs[] | "\(.workflow): \(.status)"] | join(", ")' <<<"$document")); nothing is released"
    sleep "$interval"
  done
}

cmd_release() {
  local root=$1 major=$2 rev=$3 repo=$4 sha line fields tag existing
  [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "release needs --repo OWNER/REPO"
  sha=$(git -C "$root" rev-parse --verify --quiet "$rev^{commit}") || die "no commit $rev in $root"
  line=$(state "$root" "$sha")
  read -ra fields <<<"$line"
  case ${fields[0]} in
    none)
      tag=v${fields[2]}
      if [[ ${fields[6]} != "$sha" ]]; then
        say "no release pending at ${sha:0:12}: VERSION ${fields[1]} is the release $tag it is based on"
        return 0
      fi
      # The commit is the release itself (tagged before, by this workflow or
      # by `dotsteward contribute release`): its GitHub release is completed
      # when it is missing.
      if gh release view "$tag" --repo "$repo" --json tagName </dev/null >/dev/null 2>&1; then
        say "the release $tag exists"
        return 0
      fi
      publish_release "$root" "$repo" "$tag" "$sha"
      return 0
      ;;
    mismatch)
      if [[ ${fields[3]} == - ]]; then
        die "VERSION ${fields[1]} at ${sha:0:12}: the commits since v${fields[2]} hold a breaking change, so the next release is a major one; set VERSION with tools/version.sh bump --major once the user decided it"
      fi
      die "VERSION ${fields[1]} at ${sha:0:12} is not the next release ${fields[3]} (after v${fields[2]}): set it with tools/version.sh bump in a release commit"
      ;;
  esac
  ((fields[4] == 0 || major)) ||
    die "v${fields[1]} is a major release: cut it only with --major (the workflow's major input), a decision of the user"
  tag=v${fields[1]}
  existing=$(git -C "$root" rev-parse --verify --quiet "refs/tags/$tag^{commit}") || existing=""
  [[ -z $existing || $existing == "$sha" ]] || die "the tag $tag exists at ${existing:0:12}, not at ${sha:0:12}"
  if gh release view "$tag" --repo "$repo" --json tagName </dev/null >/dev/null 2>&1; then
    say "the release $tag exists"
    return 0
  fi
  wait_main_ci "$repo" "$sha"
  publish_release "$root" "$repo" "$tag" "$sha"
}

# release_commit REPO TAG: the commit that the tag of the GitHub release TAG
# names in REPO; status 1 without that release, or when it cannot be read.
release_commit() {
  gh release view "$2" --repo "$1" --json tagName </dev/null >/dev/null 2>&1 || return 1
  gh api "repos/$1/commits/refs/tags/$2" --jq .sha </dev/null
}

# publish_release ROOT REPO TAG SHA: the GitHub release TAG at SHA (the tag
# is created there when missing) with the notes of the commits since the
# release before it, then channels.yml and macos-smoke.yml dispatched on
# the tag. `dotsteward contribute release` cuts the same release once
# main's CI is green, so it may create this GitHub release, on its own tag,
# between the look for it in cmd_release and the create here, which then
# fails: a release whose tag names SHA is that release, and nothing more is
# done (the run's tag push started channels.yml and macos-smoke.yml).
publish_release() {
  local root=$1 repo=$2 tag=$3 sha=$4 notes base workflow existing
  base=$(release_base_before "$root" "$sha" "$tag" "$(release_local_tags "$root")")
  notes=$(mktemp "${TMPDIR:-/tmp}/release-notes.XXXXXX")
  release_notes "$root" "$base" "$sha" >"$notes"
  if ! gh release create "$tag" --repo "$repo" --target "$sha" --title "$tag" --notes-file "$notes" </dev/null >/dev/null; then
    rm -f -- "$notes"
    existing=$(release_commit "$repo" "$tag") || die "gh release create $tag failed"
    [[ $existing == "$sha" ]] ||
      die "gh release create $tag failed: the release $tag exists, but its tag names ${existing:0:12}, not ${sha:0:12}"
    say "the release $tag exists at ${sha:0:12}: it was created meanwhile"
    return 0
  fi
  rm -f -- "$notes"
  say "released $tag at ${sha:0:12}: https://github.com/$repo/releases/tag/$tag"
  for workflow in channels.yml macos-smoke.yml; do
    gh workflow run "$workflow" --repo "$repo" --ref "$tag" </dev/null ||
      die "released $tag, but $workflow could not be dispatched on it; dispatch it by hand"
    say "dispatched $workflow on $tag"
  done
}

(($#)) || {
  usage >&2
  exit 1
}
command=$1
shift
root=$script_root check=0 major=0 commit=0 rev=HEAD repo=""
while (($#)); do
  case $1 in
    --check) check=1 ;;
    --major) major=1 ;;
    --commit) commit=1 ;;
    --root | --repo | --rev)
      (($# >= 2)) || die "$1 requires a value"
      case $1 in
        --root) root=$(cd "$2" && pwd -P) || die "no directory $2" ;;
        --repo) repo=$2 ;;
        --rev) rev=$2 ;;
      esac
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "unknown option: $1" ;;
    *)
      [[ $command == next || $command == notes ]] || die "unexpected argument: $1"
      rev=$1
      ;;
  esac
  shift
done
case $command in
  sync) cmd_sync "$root" "$check" ;;
  next) cmd_next "$root" "$major" "$rev" ;;
  notes) cmd_notes "$root" "$rev" ;;
  bump) cmd_bump "$root" "$major" "$commit" ;;
  release) cmd_release "$root" "$major" "$rev" "$repo" ;;
  -h | --help) usage ;;
  *) die "unknown command: $command (sync, next, notes, bump or release)" ;;
esac
