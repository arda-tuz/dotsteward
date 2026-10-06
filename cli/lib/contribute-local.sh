# shellcheck shell=bash
# The local steps of `dotsteward contribute` (SPEC 9.4 steps 0, 2, 3, 4 and
# 6): mode, setup, start and check. Sourced by cli/commands/contribute.sh,
# which provides lib.sh, config.sh, the run state helpers and the constants
# CONTRIBUTE_PRIVACY_STOP and CONTRIBUTE_DENYLIST_SHOWN; framework_root is
# the framework source of the running CLI.
#
#   contribute_cmd_mode, contribute_cmd_setup, contribute_cmd_start,
#   contribute_cmd_check     the steps (arguments as in the command usage)
#   contribute_resolve_mode  sets the CT_* facts below from the instance
#   contribute_report_fallback
#                            warns when owner mode fell back to fork mode
#   contribute_url_key URL   host/path of a git URL (scp-like, scheme or
#                            local path), without .git; GitHub paths in
#                            lower case. Two URLs of one repository share
#                            the key
#   contribute_is_clone DIR  DIR is the top of a git work tree
#   contribute_require_clean DIR
#   contribute_fetch_main DIR REMOTE
#                            fetches main of REMOTE into
#                            refs/remotes/REMOTE/main (180 s)
#   contribute_leak_terms CONTEXT_JSON ALLOWLIST BASE PUBLIC...
#                            the instance-leak terms in the denylist format:
#                            runtime and check user and home, the instance
#                            remote's owner and repository, instance
#                            component names and settings targets, the
#                            other settings targets except the catalog
#                            components', settings entry ids, instance
#                            skill names and the hostname. Skipped: terms
#                            shorter than 4 characters; terms equal to an
#                            ALLOWLIST line (the scanner masks allowlisted
#                            strings, so a term inside a longer one still
#                            finds its other occurrences); terms contained
#                            in a PUBLIC string (the contributor's user.name
#                            and user.email, which every commit carries as
#                            its unmasked author and committer, so such a
#                            term could never pass); and terms the content
#                            of BASE (a commit of CT_CLONE, the fetched
#                            upstream main; empty: no such skip) already
#                            holds outside the allowlisted strings, which
#                            are no new leak of the branch and would stop
#                            every change of a file that mentions them
#
# Facts set by contribute_resolve_mode (the remote steps use them too):
#   CT_CONTEXT          `dotsteward context --json` of the instance
#   CT_UPSTREAM         the upstream as shown: owner/repo on GitHub, else
#                       the flake reference
#   CT_UPSTREAM_SLUG    owner/repo on github.com, else empty
#   CT_UPSTREAM_NAME    the upstream repository name
#   CT_UPSTREAM_URL     the git URL of the upstream
#   CT_CONFIGURED       upstream.contribute
#   CT_MODE             owner or fork
#   CT_FALLBACK         why owner mode is not available, else empty
#   CT_UPSTREAM_REMOTE  the clone's remote for the upstream (origin in
#                       owner mode, upstream in fork mode)
#   CT_FORK_SLUG, CT_FORK_URL
#                       the fork (fork mode; empty when unknown)
#   CT_CLONE            upstream.local_clone
#   CT_GH_LOGIN, CT_GH_ID
#                       the GitHub identity from `gh api user`, else empty
#   CT_PROTOCOL         ssh or https: gh's git_protocol for github.com
#                       (https unless gh says ssh)

# --- URLs ---------------------------------------------------------------------------

contribute_url_key() {
  local url=$1 host="" path
  url=${url%/}
  if [[ $url =~ ^[A-Za-z][A-Za-z0-9+.-]*://([^/]*)(.*)$ ]]; then
    host=${BASH_REMATCH[1]}
    path=${BASH_REMATCH[2]}
    host=${host##*@}
    host=${host%%:*}
  elif [[ $url =~ ^([^/@:]+@)?([^/:]+):(.*)$ ]]; then
    host=${BASH_REMATCH[2]}
    path=${BASH_REMATCH[3]}
  else
    path=$url
  fi
  while [[ $path == //* ]]; do path=${path#/}; done
  path=/${path#/}
  path=${path%/}
  path=${path%.git}
  host=${host,,}
  [[ $host != github.com ]] || path=${path,,}
  printf '%s%s\n' "$host" "$path"
}

# _contribute_github_slug URL: owner/repo when URL is a github.com repository.
_contribute_github_slug() {
  local key
  key=$(contribute_url_key "$1")
  [[ $key =~ ^github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)$ ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# _contribute_load_protocol: CT_PROTOCOL from gh's git_protocol.
_contribute_load_protocol() {
  [[ -z ${CT_PROTOCOL:-} ]] || return 0
  CT_PROTOCOL=https
  if command -v gh >/dev/null 2>&1; then
    local answer
    answer=$(gh config get git_protocol -h github.com 2>/dev/null) || answer=""
    [[ $answer != ssh ]] || CT_PROTOCOL=ssh
  fi
}

# _contribute_github_url SLUG: the clone URL of a github.com repository.
_contribute_github_url() {
  _contribute_load_protocol
  if [[ $CT_PROTOCOL == ssh ]]; then
    printf 'git@github.com:%s.git\n' "$1"
  else
    printf 'https://github.com/%s.git\n' "$1"
  fi
}

# --- context and upstream ------------------------------------------------------------

_contribute_load_context() {
  [[ -z ${CT_CONTEXT:-} ]] || return 0
  # shellcheck disable=SC2154 # framework_root is set by cli/commands/contribute.sh
  CT_CONTEXT=$("$BASH" "$framework_root/cli/commands/context.sh" --json) ||
    die "cannot read the instance context (dotsteward context --json)"
}

# _contribute_load_upstream: CT_UPSTREAM, CT_UPSTREAM_SLUG, CT_UPSTREAM_NAME
# and CT_UPSTREAM_URL from the dotsteward input of flake.lock (D17).
_contribute_load_upstream() {
  local ref rest query host
  ref=$(jq -r '.framework.upstream // empty' <<<"$CT_CONTEXT")
  [[ -n $ref ]] || die "the instance flake.lock has no dotsteward input, so the framework upstream is unknown"
  CT_UPSTREAM_SLUG=""
  case $ref in
    github:*)
      rest=${ref#github:}
      host=github.com
      if [[ $rest == *\?* ]]; then
        query=${rest#*\?}
        rest=${rest%%\?*}
        [[ $query =~ (^|&)host=([^&]+) ]] && host=${BASH_REMATCH[2],,}
      fi
      [[ $rest =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "unsupported framework upstream for contribute: $ref"
      if [[ $host == github.com ]]; then
        CT_UPSTREAM_SLUG=$rest
        CT_UPSTREAM=$rest
        CT_UPSTREAM_URL=$(_contribute_github_url "$rest")
      else
        CT_UPSTREAM=$ref
        CT_UPSTREAM_URL=https://$host/$rest.git
      fi
      ;;
    git+*)
      CT_UPSTREAM_URL=${ref#git+}
      CT_UPSTREAM_URL=${CT_UPSTREAM_URL%%\?*}
      CT_UPSTREAM_SLUG=$(_contribute_github_slug "$CT_UPSTREAM_URL") || CT_UPSTREAM_SLUG=""
      CT_UPSTREAM=${CT_UPSTREAM_SLUG:-$ref}
      ;;
    *) die "unsupported framework upstream for contribute: $ref" ;;
  esac
  if [[ -n $CT_UPSTREAM_SLUG ]]; then
    CT_UPSTREAM_NAME=${CT_UPSTREAM_SLUG#*/}
  else
    CT_UPSTREAM_NAME=$(contribute_url_key "$CT_UPSTREAM_URL")
    CT_UPSTREAM_NAME=${CT_UPSTREAM_NAME##*/}
  fi
}

# _contribute_gh_identity: CT_GH_LOGIN and CT_GH_ID from `gh api user`;
# status 1 (both empty) when gh is missing or not logged in.
_contribute_gh_identity() {
  CT_GH_LOGIN=""
  CT_GH_ID=""
  command -v gh >/dev/null 2>&1 || return 1
  local answer login id
  answer=$(gh api user --jq '"\(.login) \(.id)"' 2>/dev/null) || return 1
  read -r login id <<<"$answer"
  [[ ${login:-} =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ && ${id:-} =~ ^[0-9]+$ ]] || return 1
  CT_GH_LOGIN=$login
  CT_GH_ID=$id
}

# --- clones -------------------------------------------------------------------------

contribute_is_clone() {
  local dir=$1 top physical
  [[ -d $dir ]] || return 1
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  physical=$(cd -P -- "$dir" && pwd)
  [[ $top == "$physical" ]]
}

# _contribute_remote_url DIR NAME: the configured URL of remote NAME, as
# written (no insteadOf rewriting); empty when there is none.
_contribute_remote_url() {
  git -C "$1" config --get "remote.$2.url" 2>/dev/null || true
}

# _contribute_same_repo URL URL
_contribute_same_repo() {
  [[ $(contribute_url_key "$1") == "$(contribute_url_key "$2")" ]]
}

contribute_require_clean() {
  local changes
  changes=$(git -C "$1" status --porcelain --untracked-files=normal) || die "cannot read the status of $1"
  [[ -z $changes ]] || die "the clone $1 has uncommitted changes; commit or remove them first"
}

contribute_fetch_main() {
  local dir=$1 remote=$2
  git_net 180 -C "$dir" fetch --quiet "$remote" "+refs/heads/main:refs/remotes/$remote/main" ||
    die "could not fetch main from $remote within 180 s"
}

# _contribute_origin_url: the URL the clone's origin must have in CT_MODE.
_contribute_origin_url() {
  if [[ $CT_MODE == owner ]]; then
    printf '%s\n' "$CT_UPSTREAM_URL"
  else
    [[ -n $CT_FORK_URL ]] ||
      die "the fork is unknown: gh is not logged in and upstream.fork is not set; run 'gh auth login' first"
    printf '%s\n' "$CT_FORK_URL"
  fi
}

# _contribute_verify_remotes ALLOW_MISSING_UPSTREAM(0|1): the clone's origin
# (and in fork mode its upstream remote) are the expected repositories.
_contribute_verify_remotes() {
  local allow_missing=$1 expected actual
  expected=$(_contribute_origin_url)
  actual=$(_contribute_remote_url "$CT_CLONE" origin)
  _contribute_same_repo "$actual" "$expected" ||
    die "the origin of $CT_CLONE is ${actual:-unset}, expected $expected"
  [[ $CT_MODE == fork ]] || return 0
  actual=$(_contribute_remote_url "$CT_CLONE" upstream)
  if [[ -z $actual && $allow_missing == 1 ]]; then
    return 0
  fi
  _contribute_same_repo "$actual" "$CT_UPSTREAM_URL" ||
    die "the upstream remote of $CT_CLONE is ${actual:-unset}, expected $CT_UPSTREAM_URL"
}

# --- mode ---------------------------------------------------------------------------

contribute_resolve_mode() {
  local push origin
  _contribute_load_context
  _contribute_load_protocol
  _contribute_load_upstream
  CT_CLONE=${DS_UPSTREAM_LOCAL_CLONE%/}
  CT_CONFIGURED=$DS_UPSTREAM_CONTRIBUTE
  CT_FALLBACK=""
  _contribute_gh_identity || true

  if [[ $CT_CONFIGURED == owner ]]; then
    if ! command -v gh >/dev/null 2>&1; then
      CT_FALLBACK="gh is not installed"
    elif ! gh auth status >/dev/null 2>&1; then
      CT_FALLBACK="gh is not logged in"
    elif [[ -z $CT_UPSTREAM_SLUG ]]; then
      CT_FALLBACK="the upstream is not a GitHub repository"
    elif ! push=$(gh api "repos/$CT_UPSTREAM_SLUG" --jq '.permissions.push' 2>/dev/null); then
      CT_FALLBACK="cannot read the permissions of $CT_UPSTREAM_SLUG"
    elif [[ $push != true ]]; then
      CT_FALLBACK="no push permission on $CT_UPSTREAM_SLUG"
    elif contribute_is_clone "$CT_CLONE"; then
      origin=$(_contribute_remote_url "$CT_CLONE" origin)
      _contribute_same_repo "$origin" "$CT_UPSTREAM_URL" ||
        CT_FALLBACK="the origin of $CT_CLONE is not the upstream"
    fi
  fi

  CT_FORK_SLUG=""
  CT_FORK_URL=""
  if [[ $CT_CONFIGURED == owner && -z $CT_FALLBACK ]]; then
    CT_MODE=owner
    CT_UPSTREAM_REMOTE=origin
  else
    CT_MODE=fork
    CT_UPSTREAM_REMOTE=upstream
    CT_FORK_SLUG=$DS_UPSTREAM_FORK
    if [[ -z $CT_FORK_SLUG && -n $CT_GH_LOGIN ]]; then
      CT_FORK_SLUG=$CT_GH_LOGIN/$CT_UPSTREAM_NAME
    fi
    [[ -z $CT_FORK_SLUG ]] || CT_FORK_URL=$(_contribute_github_url "$CT_FORK_SLUG")
  fi
}

contribute_report_fallback() {
  [[ -z $CT_FALLBACK ]] || warn "owner mode is not available ($CT_FALLBACK); using fork mode"
}

contribute_cmd_mode() {
  local json=0
  while (($#)); do
    case $1 in
      --json) json=1 ;;
      -h | --help)
        usage
        return 0
        ;;
      -*) die "unknown option: $1" ;;
      *) die "unexpected argument: $1" ;;
    esac
    shift
  done
  contribute_load_config
  contribute_resolve_mode
  contribute_report_fallback
  if ((json)); then
    jq -n --arg mode "$CT_MODE" --arg configured "$CT_CONFIGURED" --arg fallback "$CT_FALLBACK" \
      --arg upstream "$CT_UPSTREAM" --arg upstream_url "$CT_UPSTREAM_URL" \
      --arg upstream_remote "$CT_UPSTREAM_REMOTE" --arg fork "$CT_FORK_SLUG" --arg fork_url "$CT_FORK_URL" \
      --arg clone "$CT_CLONE" --arg login "$CT_GH_LOGIN" '
      def nonempty: if . == "" then null else . end;
      {schema_version: 1, mode: $mode, configured: $configured, fallback: ($fallback | nonempty),
       upstream: $upstream, upstream_url: $upstream_url, upstream_remote: $upstream_remote,
       fork: ($fork | nonempty), fork_url: ($fork_url | nonempty), clone: $clone,
       gh_login: ($login | nonempty)}'
    return 0
  fi
  log "contribute mode: $CT_MODE (upstream $CT_UPSTREAM, clone $CT_CLONE)"
  if [[ $CT_MODE == fork ]]; then
    log "fork: ${CT_FORK_SLUG:-unknown (gh is not logged in and upstream.fork is not set)}"
  fi
}

# --- setup --------------------------------------------------------------------------

# _contribute_create_fork: gh repo fork of the upstream as CT_FORK_SLUG.
_contribute_create_fork() {
  local owner=${CT_FORK_SLUG%%/*} name=${CT_FORK_SLUG#*/} args
  [[ -n $CT_UPSTREAM_SLUG ]] ||
    die "the upstream is not a GitHub repository; create the fork $CT_FORK_SLUG yourself"
  args=(repo fork "$CT_UPSTREAM_SLUG" --clone=false)
  [[ $owner == "$CT_GH_LOGIN" ]] || args+=(--org "$owner")
  [[ $name == "$CT_UPSTREAM_NAME" ]] || args+=(--fork-name "$name")
  gh "${args[@]}" </dev/null || die "gh repo fork failed for $CT_FORK_SLUG"
  log "created the fork $CT_FORK_SLUG"
}

# _contribute_clone URL ATTEMPTS: clones URL into CT_CLONE (600 s per
# attempt; a fork that was just created may need a moment).
_contribute_clone() {
  local url=$1 attempts=$2 attempt
  mkdir -p -- "$(dirname -- "$CT_CLONE")"
  for ((attempt = 1; ; attempt++)); do
    if git_net 600 clone --quiet --origin origin "$url" "$CT_CLONE"; then
      log "cloned $url into $CT_CLONE"
      return 0
    fi
    ((attempt < attempts)) || die "could not clone $url into $CT_CLONE"
    sleep 5
  done
}

_contribute_fetch_all() {
  local remote=$1
  git_net 180 -C "$CT_CLONE" fetch --quiet --prune "$remote" ||
    die "could not fetch $remote in $CT_CLONE within 180 s"
  log "fetched $remote in $CT_CLONE"
}

contribute_cmd_setup() {
  local create=0
  while (($#)); do
    case $1 in
      --create-fork) create=1 ;;
      -h | --help)
        usage
        return 0
        ;;
      -*) die "unknown option: $1" ;;
      *) die "unexpected argument: $1" ;;
    esac
    shift
  done
  [[ ${DOTSTEWARD_ASSUME_YES:-} != 1 ]] || create=1
  contribute_load_config
  contribute_resolve_mode
  contribute_report_fallback
  [[ -n $CT_GH_LOGIN ]] || die "gh is not logged in; run 'gh auth login' first (setup needs your GitHub identity)"
  if ! contribute_denylist_ready; then
    [[ $CT_MODE != owner ]] ||
      die "owner mode needs the denylist $CONTRIBUTE_DENYLIST_SHOWN with at least one private term (mode 0600)"
    warn "no denylist at $CONTRIBUTE_DENYLIST_SHOWN; check and the pre-push hook need it before anything is published"
  fi

  local origin_url exists=0 cloned=0
  origin_url=$(_contribute_origin_url)
  if [[ -e $CT_CLONE || -L $CT_CLONE ]]; then
    if contribute_is_clone "$CT_CLONE"; then
      exists=1
    elif [[ ! -d $CT_CLONE || -L $CT_CLONE || -n $(ls -A -- "$CT_CLONE") ]]; then
      die "$CT_CLONE exists and is not a git clone; move it away or set upstream.local_clone"
    fi
  fi

  if ((exists)); then
    _contribute_verify_remotes 1
  else
    local attempts=1
    if [[ $CT_MODE == fork ]] && ! gh api "repos/$CT_FORK_SLUG" --jq .full_name >/dev/null 2>&1; then
      ((create)) ||
        die "the fork $CT_FORK_SLUG does not exist; rerun with --create-fork to create it with gh repo fork, or set upstream.fork"
      _contribute_create_fork
      attempts=5
    fi
    _contribute_clone "$origin_url" "$attempts"
    cloned=1
  fi

  if [[ $CT_MODE == fork && -z $(_contribute_remote_url "$CT_CLONE" upstream) ]]; then
    git -C "$CT_CLONE" remote add upstream "$CT_UPSTREAM_URL"
  fi
  ((cloned)) || _contribute_fetch_all origin
  [[ $CT_MODE != fork ]] || _contribute_fetch_all upstream

  git -C "$CT_CLONE" config user.name "$CT_GH_LOGIN"
  git -C "$CT_CLONE" config user.email "$CT_GH_ID+$CT_GH_LOGIN@users.noreply.github.com"
  git -C "$CT_CLONE" config core.hooksPath .githooks
  log "contribute setup done: $CT_MODE mode, clone $CT_CLONE, commits as $CT_GH_LOGIN (commit with TZ=UTC)"
}

# --- start --------------------------------------------------------------------------

_contribute_valid_slug() {
  [[ $1 =~ ^[a-z0-9][a-z0-9-]*$ && ${#1} -le 60 ]]
}

# _contribute_open_run SLUG: the id of the newest run of SLUG whose step is
# not done; nothing when there is none.
_contribute_open_run() {
  local dir file found=""
  dir=$(contribute_runs_dir)
  [[ -d $dir ]] || return 0
  for file in "$dir"/*.json; do
    [[ -f $file ]] || continue
    if jq -e --arg slug "$1" 'type == "object" and .slug == $slug and .step != "done"' "$file" >/dev/null 2>&1; then
      found=$(basename -- "$file" .json)
    fi
  done
  [[ -z $found ]] || printf '%s\n' "$found"
}

_contribute_resume() {
  local id=$1 clone branch step current
  clone=$(contribute_state_get "$id" clone)
  branch=$(contribute_state_get "$id" branch)
  step=$(contribute_state_get "$id" step)
  contribute_is_clone "$clone" || die "the clone $clone of run $id is missing; run 'dotsteward contribute setup' first"
  current=$(git -C "$clone" symbolic-ref --quiet --short HEAD 2>/dev/null) || current=""
  if [[ $current != "$branch" ]]; then
    git -C "$clone" show-ref --verify --quiet "refs/heads/$branch" ||
      die "the branch $branch of run $id is missing in $clone"
    contribute_require_clean "$clone"
    git -C "$clone" switch --quiet "$branch" || die "cannot switch $clone to $branch"
  fi
  contribute_set_current "$id"
  log "resuming run $id at step $step (branch $branch in $clone)"
}

contribute_cmd_start() {
  local slug="" have_slug=0
  while (($#)); do
    case $1 in
      --slug)
        need_value "$1" "$#" "${2:-}"
        slug=$2
        have_slug=1
        shift
        ;;
      -h | --help)
        usage
        return 0
        ;;
      -*) die "unknown option: $1" ;;
      *) die "unexpected argument: $1" ;;
    esac
    shift
  done
  ((have_slug)) || die "start requires --slug SLUG"
  _contribute_valid_slug "$slug" ||
    die "invalid slug: $slug (lowercase letters, digits and dashes, starting with a letter or digit, at most 60 characters)"
  contribute_load_config

  local open
  open=$(_contribute_open_run "$slug")
  if [[ -n $open ]]; then
    _contribute_resume "$open"
    return 0
  fi

  contribute_resolve_mode
  contribute_report_fallback
  contribute_is_clone "$CT_CLONE" || die "no framework clone at $CT_CLONE; run 'dotsteward contribute setup' first"
  _contribute_verify_remotes 0
  contribute_require_clean "$CT_CLONE"
  local branch=fix/$slug base id json
  if git -C "$CT_CLONE" show-ref --verify --quiet "refs/heads/$branch"; then
    die "branch $branch exists in $CT_CLONE but no run records it; delete it or choose another slug"
  fi
  contribute_fetch_main "$CT_CLONE" "$CT_UPSTREAM_REMOTE"
  base=$(git -C "$CT_CLONE" rev-parse --verify --quiet "refs/remotes/$CT_UPSTREAM_REMOTE/main^{commit}") ||
    die "$CT_UPSTREAM_REMOTE/main is missing after the fetch"
  id=$(timestamp_utc)-$slug
  [[ ! -e $(contribute_state_file "$id") ]] || die "run $id already exists; start again in a second"
  git -C "$CT_CLONE" switch --quiet --no-track -c "$branch" "$base" ||
    die "cannot create $branch in $CT_CLONE"
  json=$(jq -n --arg id "$id" --arg slug "$slug" --arg mode "$CT_MODE" --arg clone "$CT_CLONE" \
    --arg branch "$branch" --arg base "$base" '{
      id: $id, slug: $slug, mode: $mode, clone: $clone, branch: $branch, base_sha: $base,
      test_sha: null, tested_tree: null, trial_switched: false, pr: null, merged_sha: null,
      tag: null, instance_commit: null, step: "reproduce"}')
  contribute_state_write "$id" "$json"
  contribute_set_current "$id"
  log "started run $id: branch $branch from $CT_UPSTREAM_REMOTE/main ${base:0:12} ($CT_MODE mode)"
  log "next: write the failing test in $CT_CLONE, then run: dotsteward contribute check --expect-fail <test path>"
}

# --- check --------------------------------------------------------------------------

_contribute_ere_escape() {
  local text=$1 out="" char i
  for ((i = 0; i < ${#text}; i++)); do
    char=${text:i:1}
    case $char in
      \\ | . | ^ | '$' | '*' | + | '?' | '(' | ')' | '[' | ']' | '{' | '}' | '|') out+="\\$char" ;;
      *) out+=$char ;;
    esac
  done
  printf '%s' "$out"
}

contribute_leak_terms() {
  local context=$1 allowlist=$2 base=$3 line term lower key path host public
  shift 3
  local -a candidates=() allowed=() publics=() segments=()
  local -A seen=()
  # Settings targets of catalog components are public framework names.
  mapfile -t candidates < <(jq -r '
    [.components[]? | select(.source == "catalog") | .settings_targets[]?] as $public
    | [
        .identity.runtime_user, .identity.runtime_home,
        .identity.check_username, .identity.check_home,
        (.components[]? | select(.source == "instance") | .name, .settings_targets[]?),
        (.settings.target_names[]? | select(. as $name | $public | index($name) | not)),
        (.settings.entry_ids[]?),
        (.skills.instance_skill_names[]?)
      ] | .[] | select(type == "string")' <<<"$context")
  # The instance remote's owner and repository.
  key=$(contribute_url_key "$(jq -r '.instance.remote // ""' <<<"$context")")
  path=${key#*/}
  IFS=/ read -r -a segments <<<"$path"
  if ((${#segments[@]} >= 1)); then
    candidates+=("${segments[-1]}")
  fi
  if ((${#segments[@]} >= 2)); then
    candidates+=("${segments[-2]}")
  fi
  host=$(uname -n 2>/dev/null) || host=""
  candidates+=("$host" "${host%%.*}")

  if [[ -f $allowlist ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      line=${line#"${line%%[![:space:]]*}"}
      line=${line%"${line##*[![:space:]]}"}
      [[ -z $line || $line == '#'* ]] || allowed+=("${line,,}")
    done <"$allowlist"
  fi
  for public in "$@"; do
    [[ -z $public ]] || publics+=("${public,,}")
  done

  for term in "${candidates[@]}"; do
    term=${term#"${term%%[![:space:]]*}"}
    term=${term%"${term##*[![:space:]]}"}
    ((${#term} >= 4)) || continue
    lower=${term,,}
    [[ -z ${seen[$lower]:-} ]] || continue
    seen[$lower]=1
    for public in "${allowed[@]}"; do
      [[ $public != "$lower" ]] || continue 2
    done
    for public in "${publics[@]}"; do
      [[ $public != *"$lower"* ]] || continue 2
    done
    if [[ -n $base ]] && _contribute_published "$base" "$lower" "${allowed[@]}"; then
      continue
    fi
    case $term in
      '#'* | word:* | re:*) printf 're:%s\n' "$(_contribute_ere_escape "$term")" ;;
      *) printf '%s\n' "$term" ;;
    esac
  done
}

# _contribute_published BASE TERM ALLOWED...: TERM (lower case) occurs in the
# content of commit BASE of CT_CLONE once the ALLOWED strings (lower case)
# are blanked out, as the scanner masks them before matching terms; binary
# files are ignored. Any git failure counts as absent, so the term is kept.
_contribute_published() {
  local base=$1 term=$2 found
  shift 2
  found=$(
    { git -C "$CT_CLONE" grep -h -i -I -F -e "$term" "$base" -- 2>/dev/null || true; } |
      CT_TERM=$term CT_ALLOWED=$(printf '%s\n' "$@") LC_ALL=C awk '
        BEGIN { n = split(ENVIRON["CT_ALLOWED"], list, "\n"); term = ENVIRON["CT_TERM"]; found = 0 }
        found { next }
        {
          low = tolower($0)
          for (i = 1; i <= n; i++) {
            len = length(list[i])
            if (len == 0) continue
            while ((p = index(low, list[i])) > 0) {
              pad = ""; for (j = 0; j < len; j++) pad = pad " "
              low = substr(low, 1, p - 1) pad substr(low, p + len)
            }
          }
          if (index(low, term) > 0) found = 1
        }
        END { print found }'
  )
  [[ $found == 1 ]]
}

_contribute_expect_fail() {
  local clone=$1 id=$2 step=$3 path=$4 status=0
  [[ $path != /* && /$path/ != */../* ]] || die "the test path must be relative to the clone: $path"
  [[ -e $clone/$path ]] || die "no such test in the clone: $path"
  [[ -f $clone/tests/run.sh ]] || die "the clone has no tests/run.sh"
  log "reproduction: tests/run.sh $path"
  (cd -- "$clone" && "$BASH" tests/run.sh "$path") </dev/null || status=$?
  ((status != 0)) || die "the test passes before the fix, so it does not reproduce the problem: $path"
  log "the test fails as expected: $path (exit $status)"
  if [[ $step == reproduce ]]; then
    contribute_state_update "$id" '.step = "fix"'
  fi
}

# _contribute_scan LABEL ARG...: one scan of the running framework's scanner
# in the clone; status 1 on any finding or scan failure.
_contribute_scan() {
  local label=$1
  shift
  log "privacy: $label"
  (cd -- "$CT_CLONE" && "$BASH" "$framework_root/cli/commands/scan.sh" "$@" --redact) </dev/null
}

contribute_cmd_check() {
  local id="" expect="" have_expect=0
  while (($#)); do
    case $1 in
      --expect-fail)
        need_value "$1" "$#" "${2:-}"
        expect=$2
        have_expect=1
        shift
        ;;
      --id)
        need_value "$1" "$#" "${2:-}"
        id=$2
        shift
        ;;
      -h | --help)
        usage
        return 0
        ;;
      -*) die "unknown option: $1" ;;
      *) die "unexpected argument: $1" ;;
    esac
    shift
  done
  contribute_load_config
  id=$(contribute_run_id "$id")

  local state branch mode step current
  state=$(contribute_state_read "$id")
  CT_CLONE=$(jq -r '.clone // ""' <<<"$state")
  branch=$(jq -r '.branch // ""' <<<"$state")
  mode=$(jq -r '.mode // ""' <<<"$state")
  step=$(jq -r '.step // ""' <<<"$state")
  [[ -n $CT_CLONE && -n $branch && ($mode == owner || $mode == fork) ]] ||
    die "the state file of run $id lacks its clone, branch or mode"
  contribute_is_clone "$CT_CLONE" || die "the clone $CT_CLONE of run $id is missing"
  current=$(git -C "$CT_CLONE" symbolic-ref --quiet --short HEAD 2>/dev/null) || current="a detached HEAD"
  [[ $current == "$branch" ]] || die "the clone is on $current, not on the run's branch $branch"

  if ((have_expect)); then
    _contribute_expect_fail "$CT_CLONE" "$id" "$step" "$expect"
    return 0
  fi

  contribute_require_clean "$CT_CLONE"
  local remote=origin base head tree
  [[ $mode == owner ]] || remote=upstream
  contribute_fetch_main "$CT_CLONE" "$remote"
  base=$(git -C "$CT_CLONE" rev-parse --verify --quiet "refs/remotes/$remote/main^{commit}") ||
    die "$remote/main is missing after the fetch"
  head=$(git -C "$CT_CLONE" rev-parse HEAD)
  tree=$(git -C "$CT_CLONE" rev-parse 'HEAD^{tree}')
  (($(git -C "$CT_CLONE" rev-list --count "$base..$head") > 0)) || die "no commits on $branch after $remote/main"
  contribute_denylist_ready ||
    die "the privacy scans need the denylist $CONTRIBUTE_DENYLIST_SHOWN (the pre-push hook reads it too); create it with one private term per line"

  # The instance-leak terms: a private file in a private directory, removed
  # when the command exits.
  _contribute_load_context
  CT_TERMS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dotsteward-contribute.XXXXXX")
  trap 'cleanup_temp_dir "$CT_TERMS_DIR"' EXIT
  chmod 0700 "$CT_TERMS_DIR"
  local terms=$CT_TERMS_DIR/terms count
  (
    umask 077
    contribute_leak_terms "$CT_CONTEXT" "$CT_CLONE/privacy/allowlist.txt" "$base" \
      "$(git -C "$CT_CLONE" config user.name || true)" "$(git -C "$CT_CLONE" config user.email || true)" >"$terms"
  )
  chmod 0600 "$terms"
  count=$(wc -l <"$terms")
  log "instance-leak scan: ${count//[[:space:]]/} terms from the instance context"

  local range=$base..$head
  local -a stopped=()
  _contribute_scan tree --tree || stopped+=(tree)
  _contribute_scan "commits $remote/main..$branch" --range "$range" --metadata \
    --denylist "$(contribute_denylist_path)" --require-denylist || stopped+=(commits)
  _contribute_scan "instance leak $remote/main..$branch" --range "$range" --extra-terms "$terms" ||
    stopped+=(instance-leak)
  if ((${#stopped[@]})); then
    printf '[dotsteward] ERROR: privacy hard stop (%s): nothing may be published; remove the findings from the branch, rewriting its commits, and run check again\n' \
      "${stopped[*]}" >&2
    exit "$CONTRIBUTE_PRIVACY_STOP"
  fi

  log "nix flake check in $CT_CLONE"
  nix_cmd flake check "$CT_CLONE" --no-update-lock-file --keep-going -L \
    --max-jobs "$DS_GATE_NIX_MAX_JOBS" --cores "$DS_GATE_NIX_CORES" </dev/null ||
    die "nix flake check failed in $CT_CLONE"

  [[ $(git -C "$CT_CLONE" rev-parse HEAD) == "$head" ]] || die "the clone moved during the check; run check again"
  contribute_require_clean "$CT_CLONE"
  local next=trial
  if (($(contribute_step_index "$step" || echo 0) > $(contribute_step_index publish))); then
    next=$step
  fi
  # shellcheck disable=SC2016 # jq variables
  contribute_state_update "$id" '.test_sha = $head | .tested_tree = $tree | .step = $next' \
    --arg head "$head" --arg tree "$tree" --arg next "$next"
  log "contribute check passed: ${head:0:12} (tree ${tree:0:12}) on $branch"
  log "next: dotsteward contribute trial"
}
