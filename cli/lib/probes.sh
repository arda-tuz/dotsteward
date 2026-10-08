# shellcheck shell=bash
# The probe registry runner: runs the version, presence and feature probes
# of the components of a manifest.
# Source after lib.sh (and config.sh when the instance configuration names
# the lock files); sourcing defines functions only.
#
#   run_cli_probes MANIFEST [PROFILE] [PATH_PREFIX]
#       runs the active probes of MANIFEST (a generation's
#       share/dotsteward/manifest.json, or any JSON document with a "probes"
#       list) in four phases:
#         1. every probe command must be an executable on PATH (component
#            order, then declaration order; each command once);
#         2. version probes: the extracted standard output must equal the
#            expected value as a string; the probe's exit status and its
#            standard error are ignored;
#         3. presence probes: the command must exit 0 (output discarded);
#         4. feature probes: the command must exit 0 and its combined
#            standard output and error must contain every needle (a fixed
#            string).
#       Within a phase probes run in component order (the manifest's
#       "components" list, which follows [components] order), then in
#       declaration order. PROFILE scopes the registry: a probe runs when its
#       component's profiles and its own profiles are null or list PROFILE
#       (an empty PROFILE scopes nothing) and its component's platforms are
#       null or list the manifest's "platform". The probe commands search
#       PATH_PREFIX, then the user's PATH (user_path: without the CLI's own
#       toolchain); the runner's own tools keep the inherited PATH. Every
#       probe runs with its "env" exported, its argv word for word and
#       standard input from /dev/null.
#       By default the first failure ends the process through die. With
#       DS_PROBES_KEEP_GOING=1 every failure is recorded instead, nothing is
#       printed, probes of a missing command are skipped, and the function
#       returns 1 when anything failed; the global arrays (index-aligned)
#       DS_PROBES_FAILURE_CODES, DS_PROBES_FAILURE_COMMANDS and
#       DS_PROBES_FAILURES hold the code, command and message of each
#       failure. Codes: missing-command, expected-unreadable,
#       version-mismatch, presence-failed, features-failed, needle-missing.
#   probes_select MANIFEST [PROFILE]
#       prints the active probes in run order (phase, component, declaration
#       order), one compact JSON object per line with the contract defaults
#       filled in (argv ["--version"], env {}, extract "first-line",
#       expected null, needles [], profiles null) and "index", the probe's
#       position in the manifest.
# An invalid manifest (one "[dotsteward] ERROR: invalid manifest ..." line
# per problem) always ends the process with status 1.
#
# Probe entries (lib/contract.nix probeSpec, tagged with "component" by the
# manifest): command, kind (version, presence, features), argv, env,
# extract, expected, needles, profiles.
#
# Extractors of version probes (applied to standard output):
#   first-line      the first line
#   field:<label>   the second whitespace-separated field of the first line
#                   whose first field is <label> (literal text)
#   prefix:<text>   the first line without <text>; a first line that does
#                   not start with <text> yields nothing
#   printf-vd       the dotted-decimal version (the "%vd" rendering of a
#                   version: digits separated by dots, at least two parts)
#                   wherever it stands in the output, a leading "v" dropped,
#                   for example 1.2.3 from "1.2.3", "v1.2.3" or
#                   "... (v1.2.3) built for ..."; it must not follow a
#                   letter, digit, dot, dash or underscore
#   regex:<re>      the first line matching the POSIX extended regular
#                   expression <re>: its first capture group when <re> has
#                   one, otherwise the whole match
# When an extractor yields nothing, the mismatch message says
# "found nothing" followed by the first non-empty output line.
#
# Expected values: versions:<path> reads the instance's versions lock
# (pins.versions_lock, DS_PINS_VERSIONS_LOCK, default versions.lock.json),
# skills:<path> its skills lock mirror (skills.lock, DS_SKILLS_LOCK, default
# agent/skills.lock.json); relative lock paths are below
# DOTSTEWARD_INSTANCE. <path> is dotted and every segment is a literal key.
# The value must be a non-empty string or a number (compared in its JSON
# text). A lock file is read only when a probe needs it.
#
# Messages:
#   required command not found: <command>
#   <command> version mismatch: expected <X>, found <Y>
#   <command> presence probe failed: <command> <argv> exited with status <N>
#   <command> features probe failed: <command> <argv> exited with status <N>
#     (the probe's output is printed first)
#   <command> lacks <needle>
#   cannot read the expected version of <command>: <reason>

# The validation and selection program. Input: the manifest read with
# --slurp; $profile: the profile ("" scopes nothing). Output: { errors } or
# { errors: [], regexes, commands, probes }.
# shellcheck disable=SC2016 # a jq program: jq expands its $names
_PROBES_JQ_PROGRAM='
def nonempty_string: type == "string" and length > 0;
def string_list: type == "array" and all(.[]; type == "string");
def optional_string_list: . == null or string_list;
def has_nul: [.. | strings, (objects | keys[])] | any(explode | any(. == 0));
def extract_ok:
  type == "string"
  and (. == "first-line" or . == "printf-vd"
    or (startswith("field:") and length > 6)
    or startswith("prefix:")
    or (startswith("regex:") and length > 6));
def expected_ok:
  type == "string"
  and ((startswith("versions:") and length > 9) or (startswith("skills:") and length > 7));
def env_ok:
  type == "object"
  and all(to_entries[]; (.key | test("\\A[A-Za-z_][A-Za-z0-9_]*\\z")) and (.value | type) == "string");
def allows($list; $value): $list == null or $value == "" or any($list[]; . == $value);

def component_errors:
  if .components == null then empty
  elif (.components | type) != "array" then "components is not a list"
  else
    .components | to_entries[] | .key as $i | .value as $c
    | if ($c | type) != "object" then "component \($i + 1): not an object"
      elif ($c.name | nonempty_string | not) then "component \($i + 1): name is not a non-empty string"
      else
        "component \($i + 1) (\($c.name))" as $where
        | (if $c.profiles | optional_string_list then empty
           else "\($where): profiles is not null or a list of strings" end),
          (if $c.platforms | optional_string_list then empty
           else "\($where): platforms is not null or a list of strings" end)
      end
  end;

def probe_errors($names):
  .probes | to_entries[] | .key as $i | .value as $p
  | if ($p | type) != "object" then "probe \($i + 1): not an object"
    elif ($p.command | nonempty_string | not) then "probe \($i + 1): command is not a non-empty string"
    else
      "probe \($i + 1) (\($p.command))" as $where
      | (if $p | has_nul then "\($where): a value contains a NUL character" else empty end),
        (if $p.component != null and ($p.component | type) != "string" then
           "\($where): component is not a string"
         elif $names != null and (any($names[]; . == $p.component) | not) then
           "\($where): component \($p.component // "null") is not in the manifest components"
         else empty end),
        (if any("version", "presence", "features"; . == $p.kind) then empty
         else "\($where): kind is not version, presence or features" end),
        (if $p.argv == null or ($p.argv | string_list) then empty
         else "\($where): argv is not a list of strings" end),
        (if $p.env == null or ($p.env | env_ok) then empty
         else "\($where): env is not a table of variable names to strings" end),
        (if $p.extract == null or ($p.extract | extract_ok) then empty
         else "\($where): extract is not first-line, printf-vd, field:<label>, prefix:<text> or regex:<re>" end),
        (if $p.expected == null then
           (if $p.kind == "version" then "\($where): a version probe needs expected" else empty end)
         elif $p.expected | expected_ok then empty
         else "\($where): expected is not versions:<path> or skills:<path>" end),
        (if $p.needles == null or ($p.needles | string_list) then empty
         else "\($where): needles is not a list of strings" end),
        (if $p.profiles | optional_string_list then empty
         else "\($where): profiles is not null or a list of strings" end)
    end;

def normalize($i): {
  component: (.component // null), command, kind,
  argv: (.argv // ["--version"]), env: (.env // {}), extract: (.extract // "first-line"),
  expected: (.expected // null), needles: (.needles // []), profiles: (.profiles // null),
  index: $i
};

if length != 1 then {errors: ["not a single JSON document"]}
else
  .[0]
  | if type != "object" then {errors: ["not a JSON object"]}
    elif (.probes | type) != "array" then {errors: ["probes is not a list"]}
    else
      [component_errors] as $component_errors
      | (if (.components | type) == "array" and $component_errors == [] then [.components[].name]
         else null end) as $names
      | (if .platform == null or (.platform | type) == "string" then []
         else ["platform is not a string"] end) as $platform_errors
      | ($platform_errors + $component_errors + [probe_errors($names)]) as $errors
      | if $errors != [] then {errors: $errors}
        else
          (.platform // "") as $platform
          | (if $names == null then null
             else .components | to_entries
               | map({key: .value.name, value: {position: .key, profiles: .value.profiles,
                  platforms: .value.platforms}})
               | from_entries end) as $components
          | def position: if $components == null then 0 else $components[.component].position end;
            [.probes | to_entries[] | .key as $i | .value | normalize($i)]
          | map(select(allows(.profiles; $profile)
              and ($components == null
                or ($components[.component] as $c
                  | allows($c.profiles; $profile) and allows($c.platforms; $platform)))))
          | {
              errors: [],
              regexes: [.[] | select(.extract | startswith("regex:"))
                | {where: "probe \(.index + 1) (\(.command))", re: .extract[6:]}],
              commands: (sort_by([position, .index])
                | reduce .[].command as $c ([]; if any(.[]; . == $c) then . else . + [$c] end)),
              probes: sort_by([{version: 0, presence: 1, features: 2}[.kind], position, .index])
            }
        end
    end
end
'

# _probes_load MANIFEST PROFILE: prints the selection document (errors
# empty) or reports every problem and exits 1.
_probes_load() {
  local manifest=$1 profile=$2 document line
  [[ -f $manifest ]] || die "manifest not found: $manifest"
  if ! jq empty "$manifest" >/dev/null 2>&1; then
    die "invalid manifest $manifest: not valid JSON"
  fi
  document=$(jq -c -s --arg profile "$profile" "$_PROBES_JQ_PROGRAM" "$manifest") ||
    die "cannot read the manifest: $manifest"
  local errors=() status where re
  mapfile -t errors < <(jq -r '.errors[]' <<<"$document")
  if ((${#errors[@]} == 0)); then
    # The regular expressions are checked with the engine that runs them.
    while IFS= read -r -d '' where && IFS= read -r -d '' re; do
      status=0
      # Newer bash versions also print a warning for an invalid expression.
      # shellcheck disable=SC2319 # the status of =~ itself: 2 means an invalid regex
      { [[ "" =~ $re ]]; } 2>/dev/null || status=$?
      ((status != 2)) || errors+=("$where: invalid regular expression in extract: $re")
    done < <(jq -j '.regexes[] | .where, "\u0000", .re, "\u0000"' <<<"$document")
  fi
  if ((${#errors[@]})); then
    for line in "${errors[@]}"; do
      printf '[dotsteward] ERROR: invalid manifest %s: %s\n' "$manifest" "$line" >&2
    done
    exit 1
  fi
  printf '%s\n' "$document"
}

probes_select() {
  (($# == 1 || $# == 2)) || die "usage: probes_select MANIFEST [PROFILE]"
  local document
  document=$(_probes_load "$1" "${2:-}") || exit 1
  jq -c '.probes[]' <<<"$document"
}

# _probes_fail CODE COMMAND MESSAGE: dies, or records the failure in
# keep-going mode.
_probes_fail() {
  if [[ ${DS_PROBES_KEEP_GOING:-0} == 1 ]]; then
    DS_PROBES_FAILURE_CODES+=("$1")
    DS_PROBES_FAILURE_COMMANDS+=("$2")
    DS_PROBES_FAILURES+=("$3")
    return 0
  fi
  die "$3"
}

# _probes_exec: runs the current probe (_probes_command, _probes_argv,
# _probes_env) with _probes_path as PATH and an empty standard input.
_probes_exec() {
  (
    trap - ERR
    local assignment
    for assignment in "${_probes_env[@]}"; do
      export "${assignment?}"
    done
    PATH=$_probes_path exec "$_probes_command" "${_probes_argv[@]}"
  ) </dev/null
}

# _probes_expected SPEC: sets _probes_value to the expected value of SPEC
# (versions:<path> or skills:<path>), or _probes_message to the reason and
# returns 1.
_probes_expected() {
  local spec=$1 source path relative file result
  source=${spec%%:*}
  path=${spec#*:}
  case $source in
    versions) relative=${DS_PINS_VERSIONS_LOCK:-versions.lock.json} ;;
    *) relative=${DS_SKILLS_LOCK:-agent/skills.lock.json} ;;
  esac
  if [[ $relative == /* ]]; then
    file=$relative
  elif [[ -n ${DOTSTEWARD_INSTANCE:-} ]]; then
    file=$DOTSTEWARD_INSTANCE/$relative
  else
    _probes_message="no instance for $relative (DOTSTEWARD_INSTANCE is not set)"
    return 1
  fi
  if [[ ! -f $file ]]; then
    _probes_message="lock file not found: $file"
    return 1
  fi
  if ! result=$(jq -j --arg path "$path" '
      reduce ($path | split("."))[] as $key ({found: true, value: .};
        if .found and (.value | type) == "object" and (.value | has($key))
        then {found: true, value: .value[$key]} else {found: false} end)
      | if .found | not then "L"
        elif (.value | type) == "string" and (.value | length) > 0 then "V" + .value
        elif (.value | type) == "number" then "V" + (.value | tojson)
        else "T" end' "$file" 2>/dev/null); then
    _probes_message="invalid JSON in $file"
    return 1
  fi
  case $result in
    V*)
      _probes_value=${result#V}
      return 0
      ;;
    L) _probes_message="$relative lacks $path" ;;
    *) _probes_message="$relative has no version string at $path" ;;
  esac
  return 1
}

# _probes_extract SPEC OUTPUT: sets _probes_value to the version SPEC
# extracts from OUTPUT; returns 1 when it yields nothing.
_probes_extract() {
  local spec=$1 output=$2 first line re
  first=${output%%$'\n'*}
  _probes_value=""
  case $spec in
    first-line)
      _probes_value=$first
      ;;
    field:*)
      _probes_value=$(PROBES_LABEL=${spec#field:} awk '
        ($1 "") == (ENVIRON["PROBES_LABEL"] "") { print $2; exit }' <<<"$output")
      ;;
    prefix:*)
      local prefix=${spec#prefix:}
      if [[ $first == "$prefix"* ]]; then
        _probes_value=${first#"$prefix"}
      fi
      ;;
    printf-vd)
      re='(^|[^[:alnum:]._-])v?([0-9]+([.][0-9]+)+)'
      while IFS= read -r line; do
        if [[ $line =~ $re ]]; then
          _probes_value=${BASH_REMATCH[2]}
          break
        fi
      done <<<"$output"
      ;;
    regex:*)
      re=${spec#regex:}
      while IFS= read -r line; do
        if [[ $line =~ $re ]]; then
          if ((${#BASH_REMATCH[@]} > 1)); then
            _probes_value=${BASH_REMATCH[1]}
          else
            _probes_value=${BASH_REMATCH[0]}
          fi
          break
        fi
      done <<<"$output"
      ;;
  esac
  [[ -n $_probes_value ]]
}

# _probes_found OUTPUT: "nothing", with the first non-empty line of OUTPUT.
_probes_found() {
  local line
  while IFS= read -r line; do
    if [[ -n $line ]]; then
      printf 'nothing (output: %s)' "$line"
      return 0
    fi
  done <<<"$1"
  printf 'nothing'
}

run_cli_probes() {
  (($# >= 1 && $# <= 3)) || die "usage: run_cli_probes MANIFEST [PROFILE] [PATH_PREFIX]"
  local manifest=$1 profile=${2:-} prefix=${3:-} document
  local _probes_path=$PATH _probes_command _probes_argv=() _probes_env=()
  local _probes_value _probes_message
  _probes_path=$(user_path)
  [[ -z $prefix ]] || _probes_path=$prefix:$_probes_path
  document=$(_probes_load "$manifest" "$profile") || exit 1

  declare -ga DS_PROBES_FAILURE_CODES=() DS_PROBES_FAILURE_COMMANDS=() DS_PROBES_FAILURES=()

  # Phase 1: every command first.
  local -A missing=()
  local command
  while IFS= read -r -d '' command; do
    if ! PATH=$_probes_path type -P -- "$command" >/dev/null 2>&1; then
      missing[$command]=1
      _probes_fail missing-command "$command" "required command not found: $command"
    fi
  done < <(jq -j '.commands[] | ., "\u0000"' <<<"$document")

  # Phases 2 to 4: the probes are sorted by kind.
  local count index fields position kind extract expected shown output status needle
  local needles=()
  count=$(jq '.probes | length' <<<"$document")
  for ((index = 0; index < count; index++)); do
    mapfile -d '' fields < <(jq -j --argjson i "$index" '.probes[$i]
      | [.kind, .command, .extract, (.expected // ""), (.argv | length | tostring)] + .argv
        + [(.env | length | tostring)] + (.env | to_entries | map("\(.key)=\(.value)"))
        + [(.needles | length | tostring)] + .needles
      | map(. + "\u0000") | add' <<<"$document")
    kind=${fields[0]}
    _probes_command=${fields[1]}
    extract=${fields[2]}
    expected=${fields[3]}
    position=4
    _probes_argv=("${fields[@]:position+1:fields[position]}")
    position=$((position + 1 + fields[position]))
    _probes_env=("${fields[@]:position+1:fields[position]}")
    position=$((position + 1 + fields[position]))
    needles=("${fields[@]:position+1:fields[position]}")

    [[ -z ${missing[$_probes_command]:-} ]] || continue
    shown=$_probes_command
    ((${#_probes_argv[@]} == 0)) || shown+=" ${_probes_argv[*]}"
    status=0
    case $kind in
      version)
        if ! _probes_expected "$expected"; then
          _probes_fail expected-unreadable "$_probes_command" \
            "cannot read the expected version of $_probes_command: $_probes_message"
          continue
        fi
        expected=$_probes_value
        output=$(_probes_exec) || true
        if ! _probes_extract "$extract" "$output"; then
          _probes_fail version-mismatch "$_probes_command" \
            "$_probes_command version mismatch: expected $expected, found $(_probes_found "$output")"
        elif [[ $_probes_value != "$expected" ]]; then
          _probes_fail version-mismatch "$_probes_command" \
            "$_probes_command version mismatch: expected $expected, found $_probes_value"
        fi
        ;;
      presence)
        _probes_exec >/dev/null || status=$?
        if ((status != 0)); then
          _probes_fail presence-failed "$_probes_command" \
            "$_probes_command presence probe failed: $shown exited with status $status"
        fi
        ;;
      features)
        output=$(_probes_exec 2>&1) || status=$?
        if ((status != 0)); then
          if [[ ${DS_PROBES_KEEP_GOING:-0} != 1 && -n $output ]]; then
            printf '%s\n' "$output" >&2
          fi
          _probes_fail features-failed "$_probes_command" \
            "$_probes_command features probe failed: $shown exited with status $status"
          continue
        fi
        for needle in "${needles[@]}"; do
          if [[ $output != *"$needle"* ]]; then
            _probes_fail needle-missing "$_probes_command" "$_probes_command lacks $needle"
          fi
        done
        ;;
    esac
  done
  ((${#DS_PROBES_FAILURES[@]} == 0))
}
