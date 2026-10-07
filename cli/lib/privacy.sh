# shellcheck shell=bash
# dotsteward privacy scanner core: pure bash with git, grep, awk and
# coreutils, so the pre-push hook and CI can run it without Nix. Needs bash
# 4.4 or newer. Sourced by cli/commands/scan.sh (and by later callers such as
# the hook, static checks and contribute).
#
# A scan has three steps:
#   1. configuration: ds_privacy_load_policy FILE (the framework policy) or
#      ds_privacy_load_instance_policy (an instance: generic secret rules
#      only) followed by ds_privacy_add_forbidden_path GLOB and
#      ds_privacy_add_file_rule MESSAGE ERE GLOB...; then
#      ds_privacy_load_allowlist FILE, ds_privacy_load_terms KIND FILE (KIND:
#      denylist | extra-terms);
#   2. collection between ds_privacy_begin and ds_privacy_end:
#      ds_privacy_collect_tree ROOT GIT(0|1), ds_privacy_collect_staged ROOT,
#      ds_privacy_collect_range DIR RANGE;
#   3. ds_privacy_report REDACT(0|1) METADATA(0|1): prints the findings
#      and sets DS_PRIVACY_FINDINGS, DS_PRIVACY_FILES, DS_PRIVACY_COMMITS.
#
# Collection turns everything into numbered units in a temporary directory:
# file contents (working tree files, index blobs, blobs changed by a commit),
# commit metadata (author and committer name and e-mail, then the message)
# and annotated tag metadata (tagger name and e-mail, tag name, message). Every
# collected path is also a line of one extra unit, so the content rules and
# the terms apply to paths as well. Rules run with grep over all units at
# once; findings are reported per (unit, line, rule) in collection order.
#
# Finding lines (redacted: never the matched text):
#   <rule> <path>:<line>                     file content
#   <rule> <path> (path)                     the path itself
#   <rule> commit <sha12> [<path>:<line>]    history (range scans)
#   <rule> commit|tag <sha12> <field>        commit or tag metadata
# Term rules are denylist:<n> and extra-term:<n>, n being the entry's line in
# its file. File rules are file-rule:<n>, n being the rule's position; their
# message follows the location in parentheses. With redaction, a path that contains a term or a generic match
# (one the policy does not allow) prints as path#<k> (its position in the
# scanned path list), also as the location of its file's other findings;
# forbidden-path findings print the path, since their globs are public
# policy. Without redaction ": <match>" is appended.

# --- generic patterns (the only block the scanner exempts from itself) ------
# dotsteward:patterns:begin
_DS_PRIVACY_SECRET_RULES=(
  secret-private-key '-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'
  secret-aws-key 'AKIA[0-9A-Z]{16}'
  secret-github-token 'gh[pousr]_[A-Za-z0-9]{20,}'
  secret-github-pat 'github_pat_[A-Za-z0-9_]{20,}'
  secret-google-key 'AIza[0-9A-Za-z_-]{30,}'
  secret-sk-key 'sk-[A-Za-z0-9]{20,}'
  secret-assignment "(password|passwd|api[_-]?key|access[_-]?token)[[:space:]]*[:=][[:space:]]*[^[:space:]\"']+"
)
_DS_PRIVACY_HOME_PATTERN='(^|[^A-Za-z0-9._~})-])/(home|Users)/[A-Za-z0-9._-]+'
_DS_PRIVACY_EMAIL_PATTERN='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
_DS_PRIVACY_IPV4_PATTERN='(^|[^0-9.])(10(\.[0-9]{1,3}){3}|172\.(1[6-9]|2[0-9]|3[01])(\.[0-9]{1,3}){2}|192\.168(\.[0-9]{1,3}){2})([^0-9]|$)'
_DS_PRIVACY_NON_ASCII_PATTERN=$'[\x80-\xff]+'
# dotsteward:patterns:end

# The file whose pattern block is exempt from the generic rules, and its
# marker lines.
_DS_PRIVACY_SELF=cli/lib/privacy.sh
_DS_PRIVACY_MARK_BEGIN='# dotsteward:patterns:begin'
_DS_PRIVACY_MARK_END='# dotsteward:patterns:end'

# Units are passed to grep in batches of this many file names.
_DS_PRIVACY_BATCH=512

# Prints an error and fails. DS_PRIVACY_ERRORED tells callers with an ERR
# trap that the failure was already reported.
_ds_privacy_error() {
  # shellcheck disable=SC2034 # read by the ERR trap of callers
  DS_PRIVACY_ERRORED=1
  printf '[dotsteward] ERROR: %s\n' "$*" >&2
  return 1
}

# git without replacement objects (they could hide real history) and with
# unquoted paths.
_ds_privacy_git() {
  GIT_NO_REPLACE_OBJECTS=1 git -c core.quotePath=false "$@"
}

# _ds_privacy_list WHAT SORT COMMAND [ARG...]: runs COMMAND, which prints
# NUL-terminated items, and stores them in _DS_PRIVACY_ITEMS (sorted and
# unique when SORT is 1). A failing COMMAND is an error, never an empty list.
_ds_privacy_list() {
  local what=$1 sort=$2 out=$_DS_PRIVACY_WORK/list
  shift 2
  "$@" >"$out" || {
    _ds_privacy_error "listing $what failed"
    return 1
  }
  if ((sort)); then
    LC_ALL=C sort -z -u -o "$out" "$out"
  fi
  _DS_PRIVACY_ITEMS=()
  mapfile -d '' _DS_PRIVACY_ITEMS <"$out"
}

# _ds_privacy_valid_ere REGEX: true when grep accepts REGEX as an ERE.
_ds_privacy_valid_ere() {
  local status=0
  LC_ALL=C grep -E -e "$1" </dev/null >/dev/null 2>&1 || status=$?
  ((status != 2))
}

# _ds_privacy_trim TEXT: prints TEXT without surrounding whitespace.
_ds_privacy_trim() {
  local text=$1
  text=${text#"${text%%[![:space:]]*}"}
  text=${text%"${text##*[![:space:]]}"}
  printf '%s' "$text"
}

# _ds_privacy_glob_ere GLOB: prints an anchored ERE for a glob over a
# repository-relative path, in the glob mode of the loaded policy
# (_DS_PRIVACY_GLOB_MODE):
#   path  (the framework policy) "**/" matches any number of leading
#         directories, "/**" everything below, "*" and "?" stay within one
#         path segment;
#   case  (an instance policy) the semantics of a shell `case` pattern: "*"
#         matches any characters, "/" included, "?" any one character.
# Every other character matches itself.
_ds_privacy_glob_ere() {
  local glob=$1 out="" i c
  for ((i = 0; i < ${#glob}; i++)); do
    c=${glob:i:1}
    if [[ $_DS_PRIVACY_GLOB_MODE == case ]]; then
      case $c in
        '*') ((i > 0)) && [[ ${glob:i-1:1} == '*' ]] || out+=".*" ;;
        '?') out+="." ;;
        '.' | '^' | '$' | '+' | '(' | ')' | '{' | '}' | '|' | '[' | ']' | "\\") out+="\\$c" ;;
        *) out+=$c ;;
      esac
    elif [[ ${glob:i:3} == "**/" ]]; then
      out+="(.*/)?"
      i=$((i + 2))
    elif [[ ${glob:i:2} == "**" ]]; then
      out+=".*"
      i=$((i + 1))
    elif [[ $c == "*" ]]; then
      out+="[^/]*"
    elif [[ $c == "?" ]]; then
      out+="[^/]"
    else
      case $c in
        '.' | '^' | '$' | '+' | '(' | ')' | '{' | '}' | '|' | '[' | ']' | "\\") out+="\\$c" ;;
        *) out+=$c ;;
      esac
    fi
  done
  printf '^%s$' "$out"
}

# _ds_privacy_compile_globs VAR GLOB...: stores the EREs of the globs in the
# array VAR.
_ds_privacy_compile_globs() {
  local -n _globs=$1
  local glob
  shift
  _globs=()
  for glob in "$@"; do
    _globs+=("$(_ds_privacy_glob_ere "$glob")")
  done
}

# _ds_privacy_glob_match PATH VAR: true when PATH matches an ERE of VAR.
_ds_privacy_glob_match() {
  local -n _eres=$2
  local ere
  for ere in "${_eres[@]}"; do
    [[ $1 =~ $ere ]] && return 0
  done
  return 1
}

# --- policy (a TOML subset) --------------------------------------------------
# The reader accepts: comments, [table] headers, bare keys, basic strings
# with the escapes \" \\ \n \t \r \b \f, literal strings, booleans, integers,
# arrays (multi-line, trailing comma) and inline tables. It fills
# _DS_TOML (dotted key -> value; arrays as newline-joined strings),
# _DS_TOML_TYPE (bool, int, string, array or mixed) and _DS_TOML_KEYS (keys
# in file order).

_ds_toml_fail() {
  _ds_privacy_error "$_ds_toml_file: line $_ds_toml_line: $*"
}

_ds_toml_peek() {
  _ds_toml_char=${_ds_toml_src:_ds_toml_pos:1}
}

# Skips spaces and tabs.
_ds_toml_skip_blank() {
  while _ds_toml_peek && [[ $_ds_toml_char == [[:blank:]] ]]; do
    _ds_toml_pos=$((_ds_toml_pos + 1))
  done
}

# Skips a comment up to (not including) the end of the line.
_ds_toml_skip_comment() {
  while _ds_toml_peek && [[ -n $_ds_toml_char && $_ds_toml_char != $'\n' ]]; do
    _ds_toml_pos=$((_ds_toml_pos + 1))
  done
}

# Skips blanks, comments and line breaks.
_ds_toml_skip_all() {
  while :; do
    _ds_toml_skip_blank
    _ds_toml_peek
    case $_ds_toml_char in
      '#') _ds_toml_skip_comment ;;
      $'\n')
        _ds_toml_pos=$((_ds_toml_pos + 1))
        _ds_toml_line=$((_ds_toml_line + 1))
        ;;
      $'\r') _ds_toml_pos=$((_ds_toml_pos + 1)) ;;
      *) return 0 ;;
    esac
  done
}

# After a value or header: blanks, an optional comment, then a line break or
# the end of the file.
_ds_toml_end_of_line() {
  _ds_toml_skip_blank
  _ds_toml_peek
  [[ $_ds_toml_char == '#' ]] && _ds_toml_skip_comment && _ds_toml_peek
  [[ $_ds_toml_char == $'\r' ]] && _ds_toml_pos=$((_ds_toml_pos + 1)) && _ds_toml_peek
  case $_ds_toml_char in
    '') return 0 ;;
    $'\n')
      _ds_toml_pos=$((_ds_toml_pos + 1))
      _ds_toml_line=$((_ds_toml_line + 1))
      ;;
    *) _ds_toml_fail "unexpected text after value" ;;
  esac
}

# Reads a bare key into _ds_toml_token.
_ds_toml_key() {
  local start=$_ds_toml_pos
  while _ds_toml_peek && [[ $_ds_toml_char == [A-Za-z0-9_-] ]]; do
    _ds_toml_pos=$((_ds_toml_pos + 1))
  done
  _ds_toml_token=${_ds_toml_src:start:_ds_toml_pos-start}
  [[ -n $_ds_toml_token ]] || _ds_toml_fail "expected a key"
}

# Reads a basic ("...") or literal ('...') string into _ds_toml_value.
_ds_toml_string() {
  local quote=$_ds_toml_char out=""
  _ds_toml_pos=$((_ds_toml_pos + 1))
  while :; do
    _ds_toml_peek
    case $_ds_toml_char in
      '' | $'\n') _ds_toml_fail "unterminated string" || return 1 ;;
      "$quote")
        _ds_toml_pos=$((_ds_toml_pos + 1))
        break
        ;;
      "\\")
        if [[ $quote == "'" ]]; then
          out+="\\"
        else
          _ds_toml_pos=$((_ds_toml_pos + 1))
          _ds_toml_peek
          case $_ds_toml_char in
            '"') out+='"' ;;
            "\\") out+="\\" ;;
            n) out+=$'\n' ;;
            t) out+=$'\t' ;;
            r) out+=$'\r' ;;
            b) out+=$'\b' ;;
            f) out+=$'\f' ;;
            *) _ds_toml_fail "unsupported escape in string" || return 1 ;;
          esac
        fi
        ;;
      *) out+=$_ds_toml_char ;;
    esac
    _ds_toml_pos=$((_ds_toml_pos + 1))
  done
  _ds_toml_value=$out
  _ds_toml_vtype=string
}

# Reads a string, boolean or integer into _ds_toml_value/_ds_toml_vtype.
_ds_toml_scalar() {
  _ds_toml_peek
  if [[ $_ds_toml_char == '"' || $_ds_toml_char == "'" ]]; then
    _ds_toml_string
    return
  fi
  local start=$_ds_toml_pos
  while _ds_toml_peek && [[ $_ds_toml_char == [A-Za-z0-9_.+:-] ]]; do
    _ds_toml_pos=$((_ds_toml_pos + 1))
  done
  _ds_toml_value=${_ds_toml_src:start:_ds_toml_pos-start}
  case $_ds_toml_value in
    '') _ds_toml_fail "expected a value" ;;
    true | false) _ds_toml_vtype=bool ;;
    *)
      if [[ $_ds_toml_value =~ ^[+-]?[0-9]+$ ]]; then
        _ds_toml_vtype=int
      else
        _ds_toml_fail "unsupported value"
      fi
      ;;
  esac
}

# _ds_toml_set KEY TYPE VALUE
_ds_toml_set() {
  [[ -z ${_DS_TOML_TYPE[$1]+set} ]] || {
    _ds_toml_fail "duplicate key: $1"
    return 1
  }
  _DS_TOML[$1]=$3
  _DS_TOML_TYPE[$1]=$2
  _DS_TOML_KEYS+=("$1")
}

# _ds_toml_assign KEY: parses the value at the cursor and stores it.
_ds_toml_assign() {
  local key=$1 items=() type=array inner
  _ds_toml_peek
  case $_ds_toml_char in
    '[')
      _ds_toml_pos=$((_ds_toml_pos + 1))
      while :; do
        _ds_toml_skip_all
        _ds_toml_peek
        [[ -n $_ds_toml_char ]] || {
          _ds_toml_fail "unterminated array"
          return 1
        }
        if [[ $_ds_toml_char == ']' ]]; then
          _ds_toml_pos=$((_ds_toml_pos + 1))
          break
        fi
        _ds_toml_scalar || return 1
        [[ $_ds_toml_vtype == string && $_ds_toml_value != *$'\n'* ]] || type=mixed
        items+=("$_ds_toml_value")
        _ds_toml_skip_all
        _ds_toml_peek
        case $_ds_toml_char in
          ,) _ds_toml_pos=$((_ds_toml_pos + 1)) ;;
          ']')
            _ds_toml_pos=$((_ds_toml_pos + 1))
            break
            ;;
          *)
            _ds_toml_fail "unterminated array"
            return 1
            ;;
        esac
      done
      local IFS=$'\n'
      _ds_toml_set "$key" "$type" "${items[*]}"
      ;;
    '{')
      _ds_toml_pos=$((_ds_toml_pos + 1))
      _ds_toml_skip_blank
      _ds_toml_peek
      if [[ $_ds_toml_char == '}' ]]; then
        _ds_toml_pos=$((_ds_toml_pos + 1))
        return 0
      fi
      while :; do
        _ds_toml_skip_blank
        _ds_toml_key || return 1
        inner=$_ds_toml_token
        _ds_toml_skip_blank
        _ds_toml_peek
        [[ $_ds_toml_char == '=' ]] || {
          _ds_toml_fail "expected = after key"
          return 1
        }
        _ds_toml_pos=$((_ds_toml_pos + 1))
        _ds_toml_skip_blank
        _ds_toml_assign "$key.$inner" || return 1
        _ds_toml_skip_blank
        _ds_toml_peek
        case $_ds_toml_char in
          ,) _ds_toml_pos=$((_ds_toml_pos + 1)) ;;
          '}')
            _ds_toml_pos=$((_ds_toml_pos + 1))
            break
            ;;
          *)
            _ds_toml_fail "unterminated inline table"
            return 1
            ;;
        esac
      done
      ;;
    *)
      _ds_toml_scalar || return 1
      _ds_toml_set "$key" "$_ds_toml_vtype" "$_ds_toml_value"
      ;;
  esac
}

# _ds_toml_load FILE
_ds_toml_load() {
  declare -gA _DS_TOML=() _DS_TOML_TYPE=()
  declare -ga _DS_TOML_KEYS=()
  _ds_toml_file=$1
  _ds_toml_src=$(<"$1")
  _ds_toml_pos=0
  _ds_toml_line=1
  local prefix="" name
  local -A tables=()
  while :; do
    _ds_toml_skip_all
    _ds_toml_peek
    [[ -n $_ds_toml_char ]] || break
    if [[ $_ds_toml_char == '[' ]]; then
      _ds_toml_pos=$((_ds_toml_pos + 1))
      _ds_toml_skip_blank
      name=""
      _ds_toml_peek
      if [[ $_ds_toml_char == [A-Za-z0-9_-] ]]; then
        _ds_toml_key || return 1
        name=$_ds_toml_token
      fi
      _ds_toml_skip_blank
      _ds_toml_peek
      if [[ -z $name || $_ds_toml_char != ']' ]]; then
        _ds_toml_fail "invalid table header"
        return 1
      fi
      _ds_toml_pos=$((_ds_toml_pos + 1))
      if [[ -n ${tables[$name]+set} || -n ${_DS_TOML_TYPE[$name]+set} ]]; then
        _ds_toml_fail "duplicate table: $name"
        return 1
      fi
      tables[$name]=1
      prefix=$name.
      _ds_toml_end_of_line || return 1
      continue
    fi
    _ds_toml_key || return 1
    name=$prefix$_ds_toml_token
    _ds_toml_skip_blank
    _ds_toml_peek
    [[ $_ds_toml_char == '=' ]] || {
      _ds_toml_fail "expected = after key"
      return 1
    }
    _ds_toml_pos=$((_ds_toml_pos + 1))
    _ds_toml_skip_blank
    _ds_toml_assign "$name" || return 1
    _ds_toml_end_of_line || return 1
  done
}

# _ds_privacy_policy_list VAR KEY: copies the array at KEY into VAR.
_ds_privacy_policy_list() {
  local -n _target=$1
  _target=()
  if [[ -n ${_DS_TOML[$2]:-} ]]; then
    mapfile -t _target <<<"${_DS_TOML[$2]}"
  fi
}

# _ds_privacy_policy_bool KEY: prints 1 or 0.
_ds_privacy_policy_bool() {
  if [[ ${_DS_TOML[$1]} == true ]]; then printf 1; else printf 0; fi
}

# ds_privacy_load_policy FILE
# Reads and validates privacy/policy.toml (schema_version 1) into:
#   DS_PRIVACY_GENERIC_SECRETS, DS_PRIVACY_HOME_PATHS, DS_PRIVACY_EMAILS,
#   DS_PRIVACY_PRIVATE_IPV4, DS_PRIVACY_NON_ASCII,
#   DS_PRIVACY_COMMIT_UTC_ONLY, DS_PRIVACY_DENYLIST_REQUIRED_FOR_RANGE (1/0);
#   DS_PRIVACY_HOME_ALLOW_USERS, DS_PRIVACY_HOME_ALLOW_PATHS,
#   DS_PRIVACY_EMAIL_ALLOW_DOMAINS, DS_PRIVACY_EMAIL_ALLOW_EXACT,
#   DS_PRIVACY_NON_ASCII_EXCEPT, DS_PRIVACY_FORBIDDEN_PATHS,
#   DS_PRIVACY_COMMIT_FORBIDDEN_LINES (arrays);
#   DS_PRIVACY_COMMIT_EMAIL (ERE), DS_PRIVACY_DENYLIST_PATH (as written).
# Unknown keys, wrong types, missing keys and invalid regular expressions are
# errors: a rule is never disabled by a typo.
ds_privacy_load_policy() {
  local file=$1 spec key type required entry i
  [[ -f $file && -r $file ]] || {
    _ds_privacy_error "privacy policy is missing or unreadable: $file"
    return 1
  }
  _ds_toml_load "$file" || return 1
  _DS_PRIVACY_GLOB_MODE=path

  # key:type:required, in the order errors are reported.
  local -a specs=(
    schema_version:int:1 generic_secrets:bool:1 private_ipv4:bool:1
    home_paths.enabled:bool:1 home_paths.allow_users:array:0 home_paths.allow_paths:array:0
    emails.enabled:bool:1 emails.allow_domains:array:0 emails.allow_exact:array:0
    non_ascii.enabled:bool:1 non_ascii.except_files:array:0 forbidden_paths:array:1
    commits.email:string:1 commits.utc_only:bool:1 commits.forbidden_lines:array:1
    denylist.path:string:1 denylist.required_for_range:bool:1
  )
  local -A types=()
  for spec in "${specs[@]}"; do
    IFS=: read -r key type required <<<"$spec"
    types[$key]=$type
  done
  for key in "${_DS_TOML_KEYS[@]}"; do
    [[ -n ${types[$key]:-} ]] || {
      _ds_privacy_error "$file: unknown key: $key"
      return 1
    }
  done
  for key in "${_DS_TOML_KEYS[@]}"; do
    type=${types[$key]}
    [[ ${_DS_TOML_TYPE[$key]} == "$type" ]] && continue
    case $type in
      bool) _ds_privacy_error "$file: $key must be a boolean" ;;
      int) _ds_privacy_error "$file: $key must be an integer" ;;
      string) _ds_privacy_error "$file: $key must be a string" ;;
      array) _ds_privacy_error "$file: $key must be a list of strings" ;;
    esac
    return 1
  done
  for spec in "${specs[@]}"; do
    IFS=: read -r key type required <<<"$spec"
    [[ $required == 0 || -n ${_DS_TOML_TYPE[$key]+set} ]] || {
      _ds_privacy_error "$file: missing key: $key"
      return 1
    }
  done
  [[ ${_DS_TOML[schema_version]} == 1 ]] || {
    _ds_privacy_error "$file: unsupported schema_version: ${_DS_TOML[schema_version]}"
    return 1
  }

  # shellcheck disable=SC2034 # read by callers of the library
  DS_PRIVACY_POLICY_FILE=$file
  DS_PRIVACY_GENERIC_SECRETS=$(_ds_privacy_policy_bool generic_secrets)
  DS_PRIVACY_HOME_PATHS=$(_ds_privacy_policy_bool home_paths.enabled)
  DS_PRIVACY_EMAILS=$(_ds_privacy_policy_bool emails.enabled)
  DS_PRIVACY_PRIVATE_IPV4=$(_ds_privacy_policy_bool private_ipv4)
  DS_PRIVACY_NON_ASCII=$(_ds_privacy_policy_bool non_ascii.enabled)
  DS_PRIVACY_COMMIT_UTC_ONLY=$(_ds_privacy_policy_bool commits.utc_only)
  # shellcheck disable=SC2034 # read by callers of the library (the pre-push hook)
  DS_PRIVACY_DENYLIST_REQUIRED_FOR_RANGE=$(_ds_privacy_policy_bool denylist.required_for_range)
  _ds_privacy_policy_list DS_PRIVACY_HOME_ALLOW_USERS home_paths.allow_users
  _ds_privacy_policy_list DS_PRIVACY_HOME_ALLOW_PATHS home_paths.allow_paths
  _ds_privacy_policy_list DS_PRIVACY_EMAIL_ALLOW_DOMAINS emails.allow_domains
  _ds_privacy_policy_list DS_PRIVACY_EMAIL_ALLOW_EXACT emails.allow_exact
  _ds_privacy_policy_list DS_PRIVACY_NON_ASCII_EXCEPT non_ascii.except_files
  _ds_privacy_policy_list DS_PRIVACY_FORBIDDEN_PATHS forbidden_paths
  _ds_privacy_policy_list DS_PRIVACY_COMMIT_FORBIDDEN_LINES commits.forbidden_lines
  DS_PRIVACY_COMMIT_EMAIL=${_DS_TOML[commits.email]}
  # shellcheck disable=SC2034 # read by callers of the library
  DS_PRIVACY_DENYLIST_PATH=${_DS_TOML[denylist.path]}

  local status=0
  # shellcheck disable=SC2319 # the status of =~ itself: 2 means an invalid regex
  [[ "" =~ $DS_PRIVACY_COMMIT_EMAIL ]] || status=$?
  if ((status == 2)) || ! _ds_privacy_valid_ere "$DS_PRIVACY_COMMIT_EMAIL"; then
    _ds_privacy_error "$file: commits.email is not a valid regular expression"
    return 1
  fi
  i=0
  for entry in "${DS_PRIVACY_COMMIT_FORBIDDEN_LINES[@]}"; do
    i=$((i + 1))
    _ds_privacy_valid_ere "$entry" || {
      _ds_privacy_error "$file: commits.forbidden_lines entry $i is not a valid regular expression"
      return 1
    }
  done
}

# ds_privacy_load_instance_policy
# The policy of an instance scan (SPEC 11.2): the generic secret rules only.
# Home paths, e-mail addresses, private IPv4 addresses, non-ASCII text and
# the commit rules do not apply (instance content is personal by design);
# forbidden paths and file rules start empty and their globs have shell
# `case` semantics ("*" also matches "/"), the semantics of the owner checks
# they replace. Loaded term tables are kept.
ds_privacy_load_instance_policy() {
  _DS_PRIVACY_GLOB_MODE=case
  # shellcheck disable=SC2034 # read by callers of the library
  DS_PRIVACY_POLICY_FILE=""
  DS_PRIVACY_GENERIC_SECRETS=1
  DS_PRIVACY_HOME_PATHS=0
  DS_PRIVACY_EMAILS=0
  DS_PRIVACY_PRIVATE_IPV4=0
  DS_PRIVACY_NON_ASCII=0
  DS_PRIVACY_COMMIT_UTC_ONLY=0
  # shellcheck disable=SC2034 # read by callers of the library
  DS_PRIVACY_DENYLIST_REQUIRED_FOR_RANGE=0
  DS_PRIVACY_HOME_ALLOW_USERS=()
  DS_PRIVACY_HOME_ALLOW_PATHS=()
  DS_PRIVACY_EMAIL_ALLOW_DOMAINS=()
  DS_PRIVACY_EMAIL_ALLOW_EXACT=()
  DS_PRIVACY_NON_ASCII_EXCEPT=()
  DS_PRIVACY_FORBIDDEN_PATHS=()
  DS_PRIVACY_COMMIT_FORBIDDEN_LINES=()
  DS_PRIVACY_COMMIT_EMAIL=""
  # shellcheck disable=SC2034 # read by callers of the library
  DS_PRIVACY_DENYLIST_PATH=""
  _DS_FILE_RULE_MESSAGE=()
  _DS_FILE_RULE_PATTERN=()
  _DS_FILE_RULE_GLOBS=()
}

# ds_privacy_add_forbidden_path GLOB: one more forbidden path glob.
ds_privacy_add_forbidden_path() {
  [[ -n ${1:-} ]] || {
    _ds_privacy_error "empty forbidden path glob"
    return 1
  }
  DS_PRIVACY_FORBIDDEN_PATHS+=("$1")
}

# ds_privacy_add_file_rule MESSAGE ERE GLOB...
# A file rule: lines of the files whose path matches a GLOB and that match
# ERE (case-insensitive) are findings file-rule:<n>, reported with MESSAGE.
# Errors name the rule number, never its pattern.
ds_privacy_add_file_rule() {
  local number=$((${#_DS_FILE_RULE_PATTERN[@]} + 1)) message=${1:-} pattern=${2:-} glob
  (($# >= 3)) || {
    _ds_privacy_error "privacy file rule $number: no file globs"
    return 1
  }
  shift 2
  [[ -n $message ]] || {
    _ds_privacy_error "privacy file rule $number: empty message"
    return 1
  }
  if [[ -z $pattern ]] || ! _ds_privacy_valid_ere "$pattern"; then
    _ds_privacy_error "privacy file rule $number: invalid regular expression"
    return 1
  fi
  if LC_ALL=C grep -qE -e "$pattern" <<<""; then
    _ds_privacy_error "privacy file rule $number: pattern matches the empty string"
    return 1
  fi
  for glob in "$@"; do
    [[ -n $glob && $glob != *$'\n'* ]] || {
      _ds_privacy_error "privacy file rule $number: invalid file glob"
      return 1
    }
  done
  _DS_FILE_RULE_MESSAGE+=("$message")
  _DS_FILE_RULE_PATTERN+=("$pattern")
  local IFS=$'\n'
  _DS_FILE_RULE_GLOBS+=("$*")
}

# ds_privacy_load_allowlist FILE
# Public strings: one per line, blank lines and # comments ignored. A missing
# file means none. Extra terms are matched after every entry is masked
# (case-insensitively). An entry may not contain a denylist term, so the
# allowlist never hides one: the report refuses such an entry, unless it is
# a commit e-mail address that commits.email accepts (every commit carries
# that address, so it is public by policy); denylist terms are matched after
# only those addresses are masked.
ds_privacy_load_allowlist() {
  local line number=0
  _DS_PRIVACY_ALLOW=()
  _DS_PRIVACY_ALLOW_LINE=()
  [[ -f $1 ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    number=$((number + 1))
    line=$(_ds_privacy_trim "$line")
    [[ -z $line || $line == '#'* ]] && continue
    _DS_PRIVACY_ALLOW+=("${line,,}")
    _DS_PRIVACY_ALLOW_LINE+=("$number")
  done <"$1"
}

# _ds_privacy_check_allowlist: refuses an allowlist entry that contains a
# denylist term, unless the entry is a commit e-mail address that
# commits.email accepts; fills _DS_PRIVACY_ALLOW_IDENTITY with those
# addresses. Errors name both line numbers, never an entry or a term.
_ds_privacy_check_allowlist() {
  local i j entry
  local -a opts
  _DS_PRIVACY_ALLOW_IDENTITY=()
  for i in "${!_DS_PRIVACY_ALLOW[@]}"; do
    entry=${_DS_PRIVACY_ALLOW[i]}
    if [[ -n ${DS_PRIVACY_COMMIT_EMAIL:-} && $entry =~ $DS_PRIVACY_COMMIT_EMAIL ]]; then
      _DS_PRIVACY_ALLOW_IDENTITY+=("$entry")
      continue
    fi
    for j in "${!_DS_TERM_RULE[@]}"; do
      [[ ${_DS_TERM_RULE[j]} == denylist:* ]] || continue
      case ${_DS_TERM_MODE[j]} in
        plain) opts=(-i -F) ;;
        word) opts=(-i -w -F) ;;
        re) opts=(-i -E) ;;
      esac
      if LC_ALL=C grep -q "${opts[@]}" -e "${_DS_TERM_VALUE[j]}" <<<"$entry"; then
        _ds_privacy_error "allowlist line ${_DS_PRIVACY_ALLOW_LINE[i]} contains a term of denylist line ${_DS_TERM_RULE[j]#denylist:}: the allowlist may not mask a denylist term (remove the entry or narrow the denylist entry)"
        return 1
      fi
    done
  done
}

# _ds_privacy_mask DIR ENTRY...: copies of the text units into DIR with
# every case-insensitive occurrence of an ENTRY (lower case) replaced by
# spaces, so line numbers and match positions stay.
_ds_privacy_mask() {
  local out=$1 list=$_DS_PRIVACY_WORK/mask i
  shift
  mkdir -p "$out"
  printf '%s\n' "$@" >"$list"
  for ((i = 0; i < ${#_DS_TEXT[@]}; i += _DS_PRIVACY_BATCH)); do
    (cd "$_DS_PRIVACY_WORK/u" && LC_ALL=C awk -v allow="$list" -v out="$out" '
      BEGIN { n = 0; while ((getline entry < allow) > 0) if (entry != "") list[++n] = entry; close(allow) }
      FNR == 1 { if (dest != "") close(dest); dest = out "/" FILENAME }
      {
        line = $0; low = tolower(line)
        for (i = 1; i <= n; i++) {
          len = length(list[i])
          while ((p = index(low, list[i])) > 0) {
            pad = ""; for (j = 0; j < len; j++) pad = pad " "
            line = substr(line, 1, p - 1) pad substr(line, p + len)
            low = substr(low, 1, p - 1) pad substr(low, p + len)
          }
        }
        print line > dest
      }' "${_DS_TEXT[@]:i:_DS_PRIVACY_BATCH}") || {
      _ds_privacy_error "masking the allowlist failed"
      return 1
    }
  done
}

# ds_privacy_load_terms KIND FILE
# KIND is denylist or extra-terms. Lines: plain (case-insensitive substring),
# "word:TERM" (whole word), "re:ERE" (extended regular expression); blank
# lines and # comments are ignored, surrounding whitespace is trimmed.
# Appends to the term tables and sets DS_PRIVACY_TERMS_LOADED to the number
# of entries read. Errors name the line number, never the entry.
ds_privacy_load_terms() {
  local kind=$1 file=$2 rule line number=0 mode value
  case $kind in
    denylist) rule=denylist ;;
    extra-terms) rule=extra-term ;;
    *)
      _ds_privacy_error "unknown term list kind: $kind"
      return 1
      ;;
  esac
  DS_PRIVACY_TERMS_LOADED=0
  while IFS= read -r line || [[ -n $line ]]; do
    number=$((number + 1))
    line=$(_ds_privacy_trim "$line")
    [[ -z $line || $line == '#'* ]] && continue
    case $line in
      word:*) mode=word value=${line#word:} ;;
      re:*) mode=re value=${line#re:} ;;
      *) mode=plain value=$line ;;
    esac
    [[ -n $value ]] || {
      _ds_privacy_error "$kind line $number: empty entry"
      return 1
    }
    if [[ $mode == re ]]; then
      _ds_privacy_valid_ere "$value" || {
        _ds_privacy_error "$kind line $number: invalid regular expression"
        return 1
      }
      if LC_ALL=C grep -qE -e "$value" <<<""; then
        _ds_privacy_error "$kind line $number: entry matches the empty string"
        return 1
      fi
    fi
    _DS_TERM_RULE+=("$rule:$number")
    _DS_TERM_MODE+=("$mode")
    _DS_TERM_VALUE+=("$value")
    DS_PRIVACY_TERMS_LOADED=$((DS_PRIVACY_TERMS_LOADED + 1))
  done <"$file"
}

# --- collection --------------------------------------------------------------

# ds_privacy_begin: creates the work directory and resets all state. Term
# tables loaded before survive.
ds_privacy_begin() {
  local base
  base=$(cd "${TMPDIR:-/tmp}" && pwd -P) || return 1
  _DS_PRIVACY_WORK=$(mktemp -d "$base/dotsteward-scan.XXXXXX") || return 1
  mkdir "$_DS_PRIVACY_WORK/u"
  : >"$_DS_PRIVACY_WORK/u/paths"
  _DS_SEQ=0
  _DS_PATHS=0
  _DS_CONTENT=()
  declare -gA _DS_U_KIND=() _DS_U_LABEL=() _DS_U_PATH=() _DS_U_PATHNO=()
  declare -gA _DS_PATH_SEQ=() _DS_PATHNO_OF=() _DS_SEEN_PATH=() _DS_SEEN_BLOB=() _DS_REDACT_PATH=()
  declare -gA _DS_META_EMAIL1=() _DS_META_EMAIL2=() _DS_META_TZ1=() _DS_META_TZ2=()
  DS_PRIVACY_FILES=0
  DS_PRIVACY_COMMITS=0
  DS_PRIVACY_FINDINGS=0
}

# ds_privacy_end: removes the work directory (only a real directory named
# dotsteward-* directly inside the physical temporary directory).
ds_privacy_end() {
  local dir=${_DS_PRIVACY_WORK:-} base
  [[ -n $dir ]] || return 0
  _DS_PRIVACY_WORK=""
  base=$(cd "${TMPDIR:-/tmp}" && pwd -P) || return 0
  if [[ -d $dir && ! -L $dir && $(dirname -- "$dir") == "$base" && $(basename -- "$dir") == dotsteward-* ]]; then
    rm -rf -- "$dir"
  fi
}

# _ds_privacy_add_path PATH PREFIX: records a path entry; sets _ds_seq.
_ds_privacy_add_path() {
  _DS_SEQ=$((_DS_SEQ + 1))
  _DS_PATHS=$((_DS_PATHS + 1))
  _DS_U_KIND[$_DS_SEQ]=path
  _DS_U_LABEL[$_DS_SEQ]=$2
  _DS_U_PATH[$_DS_SEQ]=$1
  _DS_U_PATHNO[$_DS_SEQ]=$_DS_PATHS
  _DS_PATH_SEQ[$_DS_PATHS]=$_DS_SEQ
  _DS_PATHNO_OF[$1]=$_DS_PATHS
  printf '%s\n' "${1//$'\n'/?}" >>"$_DS_PRIVACY_WORK/u/paths"
}

# _ds_privacy_new_unit KIND PATH PREFIX: allocates a content unit; its file
# is $_DS_PRIVACY_WORK/u/$_DS_SEQ.
_ds_privacy_new_unit() {
  _DS_SEQ=$((_DS_SEQ + 1))
  _DS_U_KIND[$_DS_SEQ]=$1
  _DS_U_PATH[$_DS_SEQ]=$2
  _DS_U_LABEL[$_DS_SEQ]=$3
  _DS_U_PATHNO[$_DS_SEQ]=""
  [[ -z $2 ]] || _DS_U_PATHNO[$_DS_SEQ]=${_DS_PATHNO_OF[$2]:-}
  _DS_CONTENT+=("$_DS_SEQ")
  [[ $1 != file ]] || DS_PRIVACY_FILES=$((DS_PRIVACY_FILES + 1))
}

# _ds_privacy_find ROOT: files and symlinks below ROOT outside .git, as
# NUL-terminated "./path" items.
_ds_privacy_find() {
  (cd "$1" && find . -name .git -prune -o \( -type f -o -type l \) -print0)
}

# ds_privacy_collect_tree ROOT GIT: git-visible files (tracked and untracked,
# not ignored) when GIT is 1, otherwise every file below ROOT outside .git
# directories. Symlinks are scanned as their link text, never followed.
ds_privacy_collect_tree() {
  local root=$1 path full target
  if [[ $2 == 1 ]]; then
    _ds_privacy_list files 1 _ds_privacy_git -C "$root" ls-files -z -co --exclude-standard || return 1
  else
    _ds_privacy_list files 1 _ds_privacy_find "$root" || return 1
  fi
  for path in "${_DS_PRIVACY_ITEMS[@]}"; do
    path=${path#./}
    full=$root/$path
    if [[ -L $full ]]; then
      target=$(readlink -- "$full") || return 1
      _ds_privacy_add_path "$path" "$path"
      _ds_privacy_new_unit file "$path" "$path"
      printf '%s\n' "$target" >"$_DS_PRIVACY_WORK/u/$_DS_SEQ" || return 1
    elif [[ -f $full ]]; then
      _ds_privacy_add_path "$path" "$path"
      _ds_privacy_new_unit file "$path" "$path"
      ln -s -- "$full" "$_DS_PRIVACY_WORK/u/$_DS_SEQ" || return 1
    fi
  done
}

# _ds_privacy_add_blob DIR MODE SHA PATH PREFIX: a path entry (once per path)
# and a content unit (once per blob) for one index or tree entry.
_ds_privacy_add_blob() {
  local dir=$1 mode=$2 sha=$3 path=$4 prefix=$5
  [[ $mode != 160000 ]] || return 0
  if [[ -z ${_DS_SEEN_PATH[$path]+set} ]]; then
    _DS_SEEN_PATH[$path]=1
    _ds_privacy_add_path "$path" "$prefix$path"
  fi
  [[ -z ${_DS_SEEN_BLOB[$sha]+set} ]] || return 0
  _DS_SEEN_BLOB[$sha]=1
  _ds_privacy_new_unit file "$path" "$prefix$path"
  _ds_privacy_git -C "$dir" cat-file blob "$sha" >"$_DS_PRIVACY_WORK/u/$_DS_SEQ" || {
    _ds_privacy_error "reading blob $sha failed"
    return 1
  }
}

# ds_privacy_collect_staged ROOT: index blobs of every path whose index entry
# differs from HEAD (every entry before the first commit). Deletions and
# submodules are skipped.
ds_privacy_collect_staged() {
  local root=$1 entry info path mode sha
  local -A wanted=()
  if _ds_privacy_git -C "$root" rev-parse --verify --quiet HEAD >/dev/null; then
    _ds_privacy_list "staged paths" 0 _ds_privacy_git -C "$root" diff --cached --name-only --no-renames \
      --diff-filter=d -z HEAD -- || return 1
  else
    _ds_privacy_list "staged paths" 0 _ds_privacy_git -C "$root" ls-files -z || return 1
  fi
  for path in "${_DS_PRIVACY_ITEMS[@]}"; do
    wanted[$path]=1
  done
  ((${#wanted[@]})) || return 0
  _ds_privacy_list "index entries" 0 _ds_privacy_git -C "$root" ls-files -s -z || return 1
  for entry in "${_DS_PRIVACY_ITEMS[@]}"; do
    info=${entry%%$'\t'*}
    path=${entry#*$'\t'}
    [[ -n ${wanted[$path]:-} ]] || continue
    read -r mode sha _ <<<"$info"
    _ds_privacy_add_blob "$root" "$mode" "$sha" "$path" "" || return 1
  done
}

# _ds_privacy_ident LINE: splits "NAME <EMAIL> SECONDS OFFSET" into
# _ds_id_name, _ds_id_email and _ds_id_tz.
_ds_privacy_ident() {
  local re='^(.*) <([^>]*)> [0-9]+ ([+-][0-9]{4})$'
  if [[ $1 =~ $re ]]; then
    _ds_id_name=${BASH_REMATCH[1]}
    _ds_id_email=${BASH_REMATCH[2]}
    _ds_id_tz=${BASH_REMATCH[3]}
  else
    _ds_id_name=$1
    _ds_id_email=""
    _ds_id_tz=""
  fi
}

# _ds_privacy_add_object DIR KIND SHA: a metadata unit for a commit or an
# annotated tag, read from the raw object (no mailmap, no replacements).
#   commit unit lines: author name, author e-mail, committer name, committer
#     e-mail, then the message;
#   tag unit lines: tagger name, tagger e-mail, tag name, then the message.
_ds_privacy_add_object() {
  local dir=$1 kind=$2 sha=$3 raw line in_body=0 name1="" email1="" tz1="" name2="" email2="" tz2=""
  local tag_name="" unit
  raw=$_DS_PRIVACY_WORK/object
  _ds_privacy_git -C "$dir" cat-file "$kind" "$sha" >"$raw" || {
    _ds_privacy_error "reading $kind $sha failed"
    return 1
  }
  _ds_privacy_new_unit "$kind" "" "$kind ${sha:0:12}"
  unit=$_DS_PRIVACY_WORK/u/$_DS_SEQ
  : >"$unit.body"
  while IFS= read -r line || [[ -n $line ]]; do
    if ((in_body)); then
      printf '%s\n' "$line" >>"$unit.body"
      continue
    fi
    case $line in
      '') in_body=1 ;;
      'author '* | 'tagger '*)
        _ds_privacy_ident "${line#* }"
        name1=$_ds_id_name email1=$_ds_id_email tz1=$_ds_id_tz
        ;;
      'committer '*)
        _ds_privacy_ident "${line#* }"
        name2=$_ds_id_name email2=$_ds_id_email tz2=$_ds_id_tz
        ;;
      'tag '*) tag_name=${line#tag } ;;
    esac
  done <"$raw"
  if [[ $kind == commit ]]; then
    printf '%s\n' "$name1" "$email1" "$name2" "$email2" >"$unit"
  else
    printf '%s\n' "$name1" "$email1" "$tag_name" >"$unit"
  fi
  cat "$unit.body" >>"$unit"
  rm -f -- "$unit.body"
  _DS_META_EMAIL1[$_DS_SEQ]=$email1
  _DS_META_TZ1[$_DS_SEQ]=$tz1
  _DS_META_EMAIL2[$_DS_SEQ]=$email2
  _DS_META_TZ2[$_DS_SEQ]=$tz2
}

# ds_privacy_collect_range DIR RANGE
# RANGE holds whitespace-separated revisions for git rev-list (A..B, B, ^A,
# A...B); none may start with "-". For every commit, oldest first: its
# metadata and the blobs it changed (merges: only paths that differ from all
# parents), then every annotated tag that points into the range or is named
# as a range end.
ds_privacy_collect_range() {
  local dir=$1 range=$2 token commit record status prefix mode sha path end list colons parents
  local -a tokens=() commits=() records=() fields=() tags=()
  local -A in_range=() seen_tag=()
  IFS=$' \t\n' read -r -d '' -a tokens <<<"$range" || true
  ((${#tokens[@]})) || {
    _ds_privacy_error "invalid range: $range"
    return 1
  }
  for token in "${tokens[@]}"; do
    [[ $token != -* ]] || {
      _ds_privacy_error "invalid range: $range"
      return 1
    }
  done
  if ! list=$(_ds_privacy_git -C "$dir" rev-list --reverse --topo-order "${tokens[@]}" -- 2>/dev/null); then
    _ds_privacy_error "invalid range: $range"
    return 1
  fi
  [[ -z $list ]] || mapfile -t commits <<<"$list"

  for commit in "${commits[@]}"; do
    in_range[$commit]=1
    DS_PRIVACY_COMMITS=$((DS_PRIVACY_COMMITS + 1))
    _ds_privacy_add_object "$dir" commit "$commit" || return 1
    prefix="commit ${commit:0:12} "
    _ds_privacy_git -C "$dir" diff-tree -r -c --root --no-renames --no-commit-id -z "$commit" \
      >"$_DS_PRIVACY_WORK/list" || {
      _ds_privacy_error "listing the changes of commit $commit failed"
      return 1
    }
    mapfile -d '' records <"$_DS_PRIVACY_WORK/list"
    for ((record = 0; record + 1 < ${#records[@]}; record += 2)); do
      status=${records[record]}
      path=${records[record + 1]}
      # ":<modes> <shas> <status>" with one colon per parent.
      colons=${status%%[!:]*}
      read -r -a fields <<<"${status#"$colons"}"
      parents=${#colons}
      mode=${fields[parents]}
      sha=${fields[2 * parents + 1]}
      [[ ! $sha =~ ^0+$ ]] || continue
      _ds_privacy_add_blob "$dir" "$mode" "$sha" "$path" "$prefix" || return 1
    done
  done

  _ds_privacy_git -C "$dir" for-each-ref --format='%(objectname) %(objecttype) %(*objectname)' refs/tags \
    >"$_DS_PRIVACY_WORK/list" || {
    _ds_privacy_error "listing tags failed"
    return 1
  }
  while read -r sha token commit; do
    [[ $token == tag && -n ${in_range[$commit]:-} ]] || continue
    tags+=("$sha")
  done <"$_DS_PRIVACY_WORK/list"
  for token in "${tokens[@]}"; do
    [[ $token != ^* ]] || continue
    end=$token
    [[ $token != *..* ]] || end=${token##*..}
    [[ -n $end ]] || continue
    if sha=$(_ds_privacy_git -C "$dir" rev-parse --verify --quiet "$end^{tag}" 2>/dev/null); then
      tags+=("$sha")
    fi
  done
  for sha in "${tags[@]}"; do
    [[ -z ${seen_tag[$sha]:-} ]] || continue
    seen_tag[$sha]=1
    _ds_privacy_add_object "$dir" tag "$sha" || return 1
  done
}

# --- matching ----------------------------------------------------------------

# _ds_privacy_grep DIR NAMES_VAR GREP_ARG...: runs grep -H -n over the named
# files of DIR in batches; prints "name:line:text". A grep error is fatal.
_ds_privacy_grep() {
  local dir=$1 status i
  local -n _names=$2
  shift 2
  for ((i = 0; i < ${#_names[@]}; i += _DS_PRIVACY_BATCH)); do
    status=0
    (cd "$dir" && LC_ALL=C grep -H -n "$@" -- "${_names[@]:i:_DS_PRIVACY_BATCH}") || status=$?
    ((status < 2)) || {
      _ds_privacy_error "grep failed (exit $status)"
      return 1
    }
  done
}

# _ds_privacy_record SEQ LINE RULE FIELD MATCH: one finding per (unit, line,
# rule). FIELD names a metadata field explicitly (dates); empty otherwise.
_ds_privacy_record() {
  local key="$1:$2:$3"
  [[ -z ${_DS_FOUND[$key]:-} ]] || return 0
  _DS_FOUND[$key]=1
  printf '%s\037%s\037%s\037%s\037%s\n' "$1" "$2" "$3" "$4" "${5//$'\037'/ }" >>"$_DS_PRIVACY_WORK/findings"
}

# _ds_privacy_exempt SEQ LINE: true for a line inside the pattern block of
# the scanner's own file.
_ds_privacy_exempt() {
  local from=${_DS_EXEMPT_FROM[$1]:-} to=${_DS_EXEMPT_TO[$1]:-}
  [[ -n $from ]] && (($2 >= from && $2 <= to))
}

# _ds_privacy_allowed RULE MATCH SEQ: true when a generic match is allowed by
# the policy (allowed users, paths, domains, addresses, files).
_ds_privacy_allowed() {
  local rule=$1 match=$2 seq=$3 item user domain lower
  case $rule in
    home-path)
      lower=${match,,}
      user=${lower#/*/}
      for item in "${DS_PRIVACY_HOME_ALLOW_USERS[@]}"; do
        [[ $user == "${item,,}" ]] && return 0
      done
      for item in "${DS_PRIVACY_HOME_ALLOW_PATHS[@]}"; do
        [[ $lower == "${item,,}" || $lower == "${item,,}"/* ]] && return 0
      done
      ;;
    email)
      lower=${match,,}
      domain=${lower##*@}
      for item in "${DS_PRIVACY_EMAIL_ALLOW_EXACT[@]}"; do
        [[ $lower == "${item,,}" ]] && return 0
      done
      for item in "${DS_PRIVACY_EMAIL_ALLOW_DOMAINS[@]}"; do
        [[ $domain == "${item,,}" || $domain == *."${item,,}" ]] && return 0
      done
      ;;
    non-ascii)
      if [[ -n ${_DS_U_PATH[$seq]:-} ]] && _ds_privacy_glob_match "${_DS_U_PATH[$seq]}" _DS_EXCEPT_ERES; then
        return 0
      fi
      ;;
  esac
  return 1
}

# _ds_privacy_generic RULE ERE: applies one generic rule to every text unit
# and to the path list.
_ds_privacy_generic() {
  local rule=$1 hits=$_DS_PRIVACY_WORK/hits name rest line match seq user pathno
  _ds_privacy_grep "$_DS_PRIVACY_WORK/u" _DS_TEXT -o -i -E -e "$2" >"$hits" || return 1
  while IFS= read -r rest; do
    name=${rest%%:*}
    rest=${rest#*:}
    line=${rest%%:*}
    match=${rest#*:}
    case $rule in
      home-path)
        # An optional delimiter byte (which may itself be a slash) precedes
        # /home/USER or /Users/USER; keep only the last two components.
        user=${match##*/}
        match=${match%/*}
        match=/${match##*/}/$user
        ;;
      private-ipv4) [[ $match =~ [0-9]+(\.[0-9]+){3} ]] && match=${BASH_REMATCH[0]} ;;
    esac
    pathno=""
    if [[ $name == paths ]]; then
      pathno=$line
      seq=${_DS_PATH_SEQ[$line]}
      line=0
    else
      seq=$name
      ! _ds_privacy_exempt "$seq" "$line" || continue
    fi
    ! _ds_privacy_allowed "$rule" "$match" "$seq" || continue
    # A path with a reported match is never printed in redacted output.
    [[ -z $pathno ]] || _DS_REDACT_PATH[$pathno]=1
    _ds_privacy_record "$seq" "$line" "$rule" "" "$match"
  done <"$hits"
}

# _ds_privacy_terms: matches every term against the units and paths:
# denylist terms after the allowlisted commit e-mail addresses are masked,
# extra terms after every allowlist entry is masked.
_ds_privacy_terms() {
  local dir hits=$_DS_PRIVACY_WORK/hits i name rest line match seq
  local deny_dir=$_DS_PRIVACY_WORK/u extra_dir=$_DS_PRIVACY_WORK/u
  local -a opts
  if ((${#_DS_PRIVACY_ALLOW_IDENTITY[@]})); then
    deny_dir=$_DS_PRIVACY_WORK/m-identity
    _ds_privacy_mask "$deny_dir" "${_DS_PRIVACY_ALLOW_IDENTITY[@]}" || return 1
  fi
  if ((${#_DS_PRIVACY_ALLOW[@]})); then
    extra_dir=$_DS_PRIVACY_WORK/m-all
    _ds_privacy_mask "$extra_dir" "${_DS_PRIVACY_ALLOW[@]}" || return 1
  fi
  for i in "${!_DS_TERM_RULE[@]}"; do
    dir=$extra_dir
    [[ ${_DS_TERM_RULE[i]} != denylist:* ]] || dir=$deny_dir
    case ${_DS_TERM_MODE[i]} in
      plain) opts=(-o -i -F) ;;
      word) opts=(-o -i -w -F) ;;
      re) opts=(-o -i -E) ;;
    esac
    _ds_privacy_grep "$dir" _DS_TEXT "${opts[@]}" -e "${_DS_TERM_VALUE[i]}" >"$hits" || return 1
    while IFS= read -r rest; do
      name=${rest%%:*}
      rest=${rest#*:}
      line=${rest%%:*}
      match=${rest#*:}
      if [[ $name == paths ]]; then
        _DS_REDACT_PATH[$line]=1
        seq=${_DS_PATH_SEQ[$line]}
        line=0
      else
        seq=$name
      fi
      _ds_privacy_record "$seq" "$line" "${_DS_TERM_RULE[i]}" "" "$match"
    done <"$hits"
  done
}

# _ds_privacy_file_rules: every file rule over the text units of the files
# its globs select (working tree files and blobs alike).
_ds_privacy_file_rules() {
  local hits=$_DS_PRIVACY_WORK/hits i seq rest name line match
  local -a globs=() units=()
  # shellcheck disable=SC2034 # filled and read through namerefs
  local -a eres=()
  for i in "${!_DS_FILE_RULE_PATTERN[@]}"; do
    mapfile -t globs <<<"${_DS_FILE_RULE_GLOBS[i]}"
    _ds_privacy_compile_globs eres "${globs[@]}"
    units=()
    for seq in "${_DS_TEXT[@]}"; do
      [[ $seq != paths && ${_DS_U_KIND[$seq]} == file ]] || continue
      _ds_privacy_glob_match "${_DS_U_PATH[$seq]}" eres && units+=("$seq")
    done
    ((${#units[@]})) || continue
    _ds_privacy_grep "$_DS_PRIVACY_WORK/u" units -o -i -E -e "${_DS_FILE_RULE_PATTERN[i]}" >"$hits" || return 1
    while IFS= read -r rest; do
      name=${rest%%:*}
      rest=${rest#*:}
      line=${rest%%:*}
      match=${rest#*:}
      _ds_privacy_record "$name" "$line" "file-rule:$((i + 1))" "" "$match"
    done <"$hits"
  done
}

# _ds_privacy_metadata: the commit rules for commit and tag units.
_ds_privacy_metadata() {
  local seq kind first second header hits=$_DS_PRIVACY_WORK/hits entry rest name line
  local -a units=()
  for seq in "${_DS_CONTENT[@]}"; do
    kind=${_DS_U_KIND[$seq]}
    [[ $kind == commit || $kind == tag ]] || continue
    units+=("$seq")
    if [[ $kind == commit ]]; then first=author second=committer; else first=tagger second=""; fi
    if [[ ! ${_DS_META_EMAIL1[$seq]} =~ $DS_PRIVACY_COMMIT_EMAIL ]]; then
      _ds_privacy_record "$seq" 2 commit-email "$first-email" "${_DS_META_EMAIL1[$seq]}"
    fi
    if ((DS_PRIVACY_COMMIT_UTC_ONLY)) && [[ ${_DS_META_TZ1[$seq]} != +0000 ]]; then
      _ds_privacy_record "$seq" 2 commit-timezone "$first-date" "${_DS_META_TZ1[$seq]}"
    fi
    [[ -n $second ]] || continue
    if [[ ! ${_DS_META_EMAIL2[$seq]} =~ $DS_PRIVACY_COMMIT_EMAIL ]]; then
      _ds_privacy_record "$seq" 4 commit-email "$second-email" "${_DS_META_EMAIL2[$seq]}"
    fi
    if ((DS_PRIVACY_COMMIT_UTC_ONLY)) && [[ ${_DS_META_TZ2[$seq]} != +0000 ]]; then
      _ds_privacy_record "$seq" 4 commit-timezone "$second-date" "${_DS_META_TZ2[$seq]}"
    fi
  done
  ((${#units[@]})) || return 0
  for entry in "${DS_PRIVACY_COMMIT_FORBIDDEN_LINES[@]}"; do
    _ds_privacy_grep "$_DS_PRIVACY_WORK/u" units -i -E -e "$entry" >"$hits" || return 1
    while IFS= read -r rest; do
      name=${rest%%:*}
      rest=${rest#*:}
      line=${rest%%:*}
      if [[ ${_DS_U_KIND[$name]} == commit ]]; then header=4; else header=3; fi
      ((line > header)) || continue
      _ds_privacy_record "$name" "$line" commit-line "" "${rest#*:}"
    done <"$hits"
  done
}

# _ds_privacy_field SEQ LINE: the metadata field name of a unit line.
_ds_privacy_field() {
  local -a names
  if [[ ${_DS_U_KIND[$1]} == commit ]]; then
    names=(author-name author-email committer-name committer-email)
  else
    names=(tagger-name tagger-email tag-name)
  fi
  if (($2 <= ${#names[@]})); then
    printf '%s' "${names[$2 - 1]}"
  else
    printf 'message:%s' "$(($2 - ${#names[@]}))"
  fi
}

# _ds_privacy_location SEQ LINE FIELD REDACT
_ds_privacy_location() {
  local seq=$1 line=$2 field=$3 redact=$4 kind label pathno
  kind=${_DS_U_KIND[$seq]}
  case $kind in
    commit | tag)
      [[ -n $field ]] || field=$(_ds_privacy_field "$seq" "$line")
      printf '%s %s' "${_DS_U_LABEL[$seq]}" "$field"
      ;;
    *)
      label=${_DS_U_LABEL[$seq]}
      pathno=${_DS_U_PATHNO[$seq]}
      if ((redact)) && [[ -n ${_DS_REDACT_PATH[$pathno]:-} ]]; then
        label=${label%"${_DS_U_PATH[$seq]}"}path#$pathno
      fi
      if [[ $kind == path ]]; then
        printf '%s (path)' "$label"
      else
        printf '%s:%s' "$label" "$line"
      fi
      ;;
  esac
}

# ds_privacy_report REDACT METADATA
# Applies every rule to the collected units, prints one line per finding in
# collection order and sets DS_PRIVACY_FINDINGS. Returns 1 on an error.
ds_privacy_report() {
  local redact=$1 metadata=$2 seq i from to rule location
  local -a names=()
  declare -gA _DS_FOUND=() _DS_EXEMPT_FROM=() _DS_EXEMPT_TO=()
  declare -ga _DS_FORBIDDEN_ERES=() _DS_EXCEPT_ERES=()
  _ds_privacy_check_allowlist || return 1
  _ds_privacy_compile_globs _DS_FORBIDDEN_ERES "${DS_PRIVACY_FORBIDDEN_PATHS[@]}"
  _ds_privacy_compile_globs _DS_EXCEPT_ERES "${DS_PRIVACY_NON_ASCII_EXCEPT[@]}"
  : >"$_DS_PRIVACY_WORK/findings"

  # Text units: grep lists the files with at least one line and no NUL byte.
  for seq in "${_DS_CONTENT[@]}"; do
    names+=("$seq")
  done
  _DS_TEXT=()
  if ((${#names[@]})); then
    _ds_privacy_grep "$_DS_PRIVACY_WORK/u" names -I -l -e '' >"$_DS_PRIVACY_WORK/text" || return 1
    mapfile -t _DS_TEXT <"$_DS_PRIVACY_WORK/text"
  fi
  ((_DS_PATHS == 0)) || _DS_TEXT+=(paths)

  # The pattern block of the scanner's own file.
  for seq in "${_DS_TEXT[@]}"; do
    [[ $seq != paths && ${_DS_U_KIND[$seq]} == file && ${_DS_U_PATH[$seq]} == "$_DS_PRIVACY_SELF" ]] || continue
    from=$(LC_ALL=C grep -n -x -F -m 1 -e "$_DS_PRIVACY_MARK_BEGIN" "$_DS_PRIVACY_WORK/u/$seq" || true)
    from=${from%%:*}
    [[ -n $from ]] || continue
    to=$(LC_ALL=C tail -n "+$from" "$_DS_PRIVACY_WORK/u/$seq" | grep -n -x -F -m 1 -e "$_DS_PRIVACY_MARK_END" || true)
    to=${to%%:*}
    [[ -n $to ]] || continue
    _DS_EXEMPT_FROM[$seq]=$from
    _DS_EXEMPT_TO[$seq]=$((from + to - 1))
  done

  if ((${#_DS_TEXT[@]})); then
    if ((DS_PRIVACY_GENERIC_SECRETS)); then
      for ((i = 0; i < ${#_DS_PRIVACY_SECRET_RULES[@]}; i += 2)); do
        _ds_privacy_generic "${_DS_PRIVACY_SECRET_RULES[i]}" "${_DS_PRIVACY_SECRET_RULES[i + 1]}" || return 1
      done
    fi
    if ((DS_PRIVACY_HOME_PATHS)); then
      _ds_privacy_generic home-path "$_DS_PRIVACY_HOME_PATTERN" || return 1
    fi
    if ((DS_PRIVACY_EMAILS)); then
      _ds_privacy_generic email "$_DS_PRIVACY_EMAIL_PATTERN" || return 1
    fi
    if ((DS_PRIVACY_PRIVATE_IPV4)); then
      _ds_privacy_generic private-ipv4 "$_DS_PRIVACY_IPV4_PATTERN" || return 1
    fi
    if ((DS_PRIVACY_NON_ASCII)); then
      _ds_privacy_generic non-ascii "$_DS_PRIVACY_NON_ASCII_PATTERN" || return 1
    fi
    if ((${#_DS_TERM_RULE[@]})); then
      _ds_privacy_terms || return 1
    fi
    if ((${#_DS_FILE_RULE_PATTERN[@]})); then
      _ds_privacy_file_rules || return 1
    fi
  fi

  if ((${#DS_PRIVACY_FORBIDDEN_PATHS[@]})); then
    for ((i = 1; i <= _DS_PATHS; i++)); do
      seq=${_DS_PATH_SEQ[$i]}
      if _ds_privacy_glob_match "${_DS_U_PATH[$seq]}" _DS_FORBIDDEN_ERES; then
        _ds_privacy_record "$seq" 0 forbidden-path "" ""
      fi
    done
  fi

  if ((metadata)); then
    _ds_privacy_metadata || return 1
  fi

  local line field match number
  while IFS=$'\037' read -r seq line rule field match; do
    location=$(_ds_privacy_location "$seq" "$line" "$field" "$redact")
    if [[ $rule == file-rule:* ]]; then
      number=${rule#file-rule:}
      location+=" (${_DS_FILE_RULE_MESSAGE[number - 1]})"
    fi
    if ((redact)) || [[ -z $match ]]; then
      printf '%s %s\n' "$rule" "$location"
    else
      printf '%s %s: %s\n' "$rule" "$location" "$match"
    fi
    DS_PRIVACY_FINDINGS=$((DS_PRIVACY_FINDINGS + 1))
  done < <(LC_ALL=C sort -t $'\037' -k1,1n -k2,2n -k3,3 "$_DS_PRIVACY_WORK/findings")
}

# Term tables and file rules start empty when the library is sourced; globs
# have path semantics until a policy is loaded.
_DS_PRIVACY_GLOB_MODE=path
_DS_FILE_RULE_MESSAGE=()
_DS_FILE_RULE_PATTERN=()
_DS_FILE_RULE_GLOBS=()
_DS_TERM_RULE=()
_DS_TERM_MODE=()
_DS_TERM_VALUE=()
_DS_PRIVACY_ALLOW=()
_DS_PRIVACY_ALLOW_LINE=()
_DS_PRIVACY_ALLOW_IDENTITY=()
