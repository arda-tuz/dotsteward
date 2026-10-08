#!/usr/bin/env bash
# Installs the dotsteward-init skill through the three distribution
# channels, each in its own clean temporary HOME, and checks what landed:
#
#   claude-code  the Claude Code plugin marketplace (.claude-plugin/
#                marketplace.json): `claude plugin marketplace add`, then
#                `claude plugin install dotsteward@dotsteward`;
#   codex        the Codex plugin marketplace (.agents/plugins/
#                marketplace.json): `codex plugin marketplace add`, then
#                `codex plugin add dotsteward@dotsteward`;
#   skills       a generic skills installer that discovers
#                **/skills/<name>/SKILL.md in a repository (`gh skill
#                install`): the skill must be discovered under
#                plugins/dotsteward/skills/ and resolve by its bare name, then
#                it is installed for Claude Code and for Codex at user scope.
#
# Every channel must report the plugin enabled at the version of VERSION
# (the skills installer has no plugin version), and the installed
# dotsteward-init tree must equal plugins/dotsteward/skills/dotsteward-init of
# this checkout file by file (the skills installer rewrites the SKILL.md
# front matter, so there its name and body are compared). The plugin of each
# marketplace must contain no other skill.
#
# Usage: tests/channels/local-install.sh [--repo OWNER/REPO --ref REF] [CHANNEL...]
#
#   CHANNEL         claude-code, codex or skills; default: all three
#   --repo, --ref   install from the GitHub repository OWNER/REPO at the
#                   branch or tag REF instead of from this checkout. REF must
#                   point at the commit checked out here (HEAD), which is
#                   checked: the Claude Code marketplace clones REF (it takes
#                   no commit), Codex and the skills installer get the commit
#                   itself. A private repository needs GH_TOKEN (or a gh
#                   login, whose token is used): git reads it through
#                   `gh auth setup-git` in each temporary HOME, so it is never
#                   written to a file.
#
# Needs claude, codex, gh (with `gh skill`), git and jq on PATH. Nothing
# outside the temporary directory is changed; it is deleted at the end.
# Exit 0 when every channel passed, 1 otherwise.
set -Eeuo pipefail

die() {
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then
    printf '::error title=channels::%s\n' "$*"
  fi
  printf '[dotsteward] ERROR: channels: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[dotsteward] channels: %s\n' "$*" >&2
}

usage() {
  sed -n '2,/^set -Eeuo pipefail$/{/^set /d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"
}

repo=''
ref=''
channels=()
while (($# > 0)); do
  case $1 in
    -h | --help)
      usage
      exit 0
      ;;
    --repo)
      (($# >= 2)) || die "--repo needs OWNER/REPO"
      repo=$2
      shift 2
      ;;
    --ref)
      (($# >= 2)) || die "--ref needs a branch or tag"
      ref=$2
      shift 2
      ;;
    claude-code | codex | skills)
      channels+=("$1")
      shift
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
((${#channels[@]} > 0)) || channels=(claude-code codex skills)
if [[ -n $repo || -n $ref ]]; then
  [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--repo must be OWNER/REPO"
  [[ -n $ref && $ref != -* ]] || die "--ref must name a branch or tag"
fi

for tool in claude codex gh git jq; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required on PATH"
done
gh skill install --help >/dev/null 2>&1 || die "this gh has no 'gh skill' command; a newer gh is required"

root=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
skill_src=$root/plugins/dotsteward/skills/dotsteward-init
[[ -f $root/VERSION && -f $skill_src/SKILL.md ]] || die "not a dotsteward checkout: $root"
version=$(<"$root/VERSION")
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION is not MAJOR.MINOR.PATCH: $version"

sha=''
if [[ -n $repo ]]; then
  sha=$(git -C "$root" rev-parse --verify 'HEAD^{commit}') || die "cannot read the commit of this checkout"
  if [[ -z ${GH_TOKEN:-} ]]; then
    GH_TOKEN=$(gh auth token 2>/dev/null) || die "GH_TOKEN is not set and gh is not logged in"
  fi
  export GH_TOKEN
  source_label="github.com/$repo at $ref (${sha:0:12})"
else
  source_label="this checkout ($root)"
fi

work=$(mktemp -d)
cleanup() {
  rm -rf -- "$work"
}
trap cleanup EXIT

# The checks of all channels run; the failures are counted and reported.
failures=0
fail() {
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then
    printf '::error title=channels %s::%s\n' "$channel" "$*"
  fi
  printf '[dotsteward] FAIL: channels %s: %s\n' "$channel" "$*" >&2
  failures=$((failures + 1))
}

# isolate NAME: a new empty HOME for one channel. Only PATH, the locale, the
# terminal and the GitHub token cross into it; every tool configuration,
# cache and state directory is below it (Claude Code and Codex use their
# default ~/.claude and ~/.codex), and no SSH agent is reachable, so git
# clones use HTTPS like on a fresh machine.
isolate() {
  local home=$work/$1/home
  mkdir -p "$home"
  run_env=(env -i
    "PATH=$PATH" "HOME=$home" "USER=${USER:-$(id -un)}" "LANG=${LANG:-C.UTF-8}" "TERM=dumb" "TMPDIR=$work/$1"
    "XDG_CONFIG_HOME=$home/.config" "XDG_CACHE_HOME=$home/.cache"
    "XDG_DATA_HOME=$home/.local/share" "XDG_STATE_HOME=$home/.local/state"
    "DISABLE_AUTOUPDATER=1" "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
    "GIT_TERMINAL_PROMPT=0" "GIT_CONFIG_NOSYSTEM=1" "NO_COLOR=1" "GH_PROMPT_DISABLED=1")
  if [[ -n ${GH_TOKEN:-} ]]; then
    run_env+=("GH_TOKEN=$GH_TOKEN")
  fi
  channel_home=$home
  channel_log=$work/$1/log
  : >"$channel_log"
  if [[ -n $repo ]]; then
    in_home gh auth setup-git --hostname github.com || return 1
  fi
}

# in_home COMMAND [ARG...]: COMMAND in the channel's HOME, from inside it,
# with its output appended to the channel log (printed on a failure).
in_home() {
  printf '$ %s\n' "$*" >>"$channel_log"
  (cd "$channel_home" && "${run_env[@]}" "$@") >>"$channel_log" 2>&1
}

# capture COMMAND [ARG...]: like in_home, but stdout is printed for the caller.
capture() {
  printf '$ %s\n' "$*" >>"$channel_log"
  (cd "$channel_home" && "${run_env[@]}" "$@") 2>>"$channel_log"
}

show_log() {
  printf '::group::%s\n' "log of the $channel channel" >&2
  cat -- "$channel_log" >&2
  printf '::endgroup::\n' >&2
}

# same_tree INSTALLED: INSTALLED holds exactly the files of the skill source,
# byte for byte, with the same executable bits.
same_tree() {
  local installed=$1 ok=0 rel
  if [[ ! -d $installed ]]; then
    fail "the skill directory was not installed: $installed"
    return 1
  fi
  if ! diff -r -- "$skill_src" "$installed" >>"$channel_log" 2>&1; then
    fail "$installed differs from plugins/dotsteward/skills/dotsteward-init (diff in the log)"
    ok=1
  fi
  while IFS= read -r -d '' rel; do
    if [[ -x $skill_src/$rel ]]; then
      [[ -x $installed/$rel ]] || {
        fail "$rel lost its executable bit in $installed"
        ok=1
      }
    elif [[ -x $installed/$rel ]]; then
      fail "$rel became executable in $installed"
      ok=1
    fi
  done < <(cd "$skill_src" && find . -type f -print0)
  return "$ok"
}

# same_skill_md INSTALLED_DIR: the skills installer rewrites the front matter
# of SKILL.md (it adds its tracking metadata and drops the blank lines after
# it), so the name in it and the body after it are compared; every other file
# must be identical.
body_of() {
  awk 'n >= 2 && (seen || NF) { seen = 1; print } /^---$/ { n++ }' "$1"
}
same_skill_md() {
  local installed=$1 ok=0
  if [[ ! -f $installed/SKILL.md ]]; then
    fail "SKILL.md was not installed in $installed"
    return 1
  fi
  if ! diff -r -x SKILL.md -- "$skill_src" "$installed" >>"$channel_log" 2>&1; then
    fail "$installed differs from plugins/dotsteward/skills/dotsteward-init (diff in the log)"
    ok=1
  fi
  if ! diff <(body_of "$skill_src/SKILL.md") <(body_of "$installed/SKILL.md") >>"$channel_log" 2>&1; then
    fail "the body of $installed/SKILL.md differs from the source"
    ok=1
  fi
  if ! awk '/^---$/ { n++; next } n == 1' "$installed/SKILL.md" | grep -qx 'name: dotsteward-init'; then
    fail "the front matter of $installed/SKILL.md does not name dotsteward-init"
    ok=1
  fi
  return "$ok"
}

# only_skill DIR: the skills directory of an installed plugin holds the
# dotsteward-init skill and nothing else (the only channel-distributed
# skill).
only_skill() {
  local entries
  entries=$(cd "$1" 2>/dev/null && find . -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | paste -sd' ')
  [[ $entries == dotsteward-init ]] || fail "the plugin's skills directory holds '$entries', expected only dotsteward-init"
}

check_claude_code() {
  local source listing install_path marketplace_dir head
  if [[ -n $repo ]]; then
    source="https://github.com/$repo.git#$ref"
  else
    source=$root
  fi
  in_home claude plugin marketplace add "$source" || {
    fail "claude plugin marketplace add $source failed"
    return 1
  }
  in_home claude plugin install dotsteward@dotsteward || {
    fail "claude plugin install dotsteward@dotsteward failed"
    return 1
  }
  if [[ -n $repo ]]; then
    marketplace_dir=$(capture claude plugin marketplace list --json |
      jq -r '.[] | select(.name == "dotsteward") | .installLocation // empty') || true
    head=$(git -C "$marketplace_dir" rev-parse HEAD 2>>"$channel_log") || head=''
    [[ $head == "$sha" ]] ||
      fail "the marketplace clone of $ref is at '${head:-nothing}', not at the checked-out commit $sha"
  fi
  listing=$(capture claude plugin list --json) || {
    fail "claude plugin list --json failed"
    return 1
  }
  install_path=$(jq -r --arg v "$version" '.[] | select(.id == "dotsteward@dotsteward" and .version == $v
    and .enabled == true and .scope == "user") | .installPath' <<<"$listing") || install_path=''
  if [[ -z $install_path ]]; then
    printf '%s\n' "$listing" >>"$channel_log"
    fail "claude plugin list does not show dotsteward@dotsteward $version enabled at user scope"
    return 1
  fi
  [[ $install_path == "$channel_home/.claude/plugins/cache/dotsteward/dotsteward/$version" ]] ||
    fail "the plugin was installed at $install_path, not at the $version cache path"
  only_skill "$install_path/skills"
  same_tree "$install_path/skills/dotsteward-init"
}

check_codex() {
  local listing install_path=$channel_home/.codex/plugins/cache/dotsteward/dotsteward/$version
  local -a add
  if [[ -n $repo ]]; then
    add=(codex plugin marketplace add "https://github.com/$repo.git" --ref "$sha")
  else
    add=(codex plugin marketplace add "$root")
  fi
  in_home "${add[@]}" || {
    fail "${add[*]} failed"
    return 1
  }
  in_home codex plugin add dotsteward@dotsteward || {
    fail "codex plugin add dotsteward@dotsteward failed"
    return 1
  }
  listing=$(capture codex plugin list --json) || {
    fail "codex plugin list --json failed"
    return 1
  }
  if ! jq -e --arg v "$version" '[.installed[] | select(.pluginId == "dotsteward@dotsteward" and .version == $v
    and .installed == true and .enabled == true)] | length == 1' <<<"$listing" >/dev/null; then
    printf '%s\n' "$listing" >>"$channel_log"
    fail "codex plugin list does not show dotsteward@dotsteward $version installed and enabled"
    return 1
  fi
  only_skill "$install_path/skills"
  same_tree "$install_path/skills/dotsteward-init"
}

check_skills() {
  local listing matches agent dir
  local -a source pin=()
  if [[ -n $repo ]]; then
    source=("$repo")
    pin=(--pin "$sha")
  else
    source=("$root" --from-local)
  fi
  # Without a skill name and without a terminal, the installer lists what it
  # discovered (one tab-separated line per skill) and installs nothing.
  listing=$(capture gh skill install "${source[@]}" "${pin[@]}") || {
    fail "listing the skills of the repository failed"
    return 1
  }
  printf '%s\n' "$listing" >>"$channel_log"
  matches=$(cut -f1 <<<"$listing" | grep -cE '(^|[ /])dotsteward-init$' || true)
  [[ $matches == 1 ]] || {
    fail "the installer discovered dotsteward-init $matches times, expected once (listing in the log)"
    return 1
  }
  grep -qE '(^|[] ])dotsteward/dotsteward-init'$'\t' <<<"$listing" ||
    fail "dotsteward-init was not discovered under plugins/dotsteward/skills/ (listing in the log)"
  for agent in claude-code codex; do
    in_home gh skill install "${source[@]}" dotsteward-init "${pin[@]}" --agent "$agent" --scope user --force || {
      fail "gh skill install dotsteward-init --agent $agent failed"
      continue
    }
    case $agent in
      claude-code) dir=$channel_home/.claude/skills/dotsteward-init ;;
      codex) dir=$channel_home/.agents/skills/dotsteward-init ;;
    esac
    same_skill_md "$dir"
  done
}

log "installing dotsteward-init $version from $source_label"
for channel in "${channels[@]}"; do
  before=$failures
  if ! isolate "$channel"; then
    fail "preparing the temporary HOME failed"
  else
    case $channel in
      claude-code) check_claude_code || true ;;
      codex) check_codex || true ;;
      skills) check_skills || true ;;
    esac
  fi
  if ((failures == before)); then
    log "$channel: ok"
  else
    show_log
  fi
done

((failures == 0)) || die "$failures check(s) failed"
log "all channels installed dotsteward-init $version"
