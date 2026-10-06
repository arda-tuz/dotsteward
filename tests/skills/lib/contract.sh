# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Skill contract checks C1-C10 (SPEC 9.1, 9.5, 12.4). Not a test file: the
# tests in tests/skills source it after tests/lib/harness.sh and
# tests/lib/assert.sh.
#
#   C1  SKILL.md frontmatter: name equal to the directory (lowercase words
#       joined by hyphens, at most 64 characters), a description of at most
#       1024 characters without XML tags; no symlinks in the skill tree and
#       no finding of `dotsteward scan --tree --redact` over it
#   C2  agents/openai.yaml: interface.display_name, short_description and a
#       default_prompt that mentions $<name>
#   C3  LICENSE: byte-identical to the framework LICENSE (MIT, dotsteward
#       contributors)
#   C4  references/: only *.md files, at least one; every references/<f>.md
#       mentioned in SKILL.md or a reference exists; every reference file
#       is mentioned in SKILL.md (no orphans)
#   C5  every `dotsteward <command> [step] [--flag]` in a fenced block of
#       SKILL.md or a reference exists: `dotsteward <command> --help`
#       succeeds and prints the step and every flag (the step's own --help
#       counts for flags too); the launcher form `.dotsteward/cli.sh` is
#       checked the same way
#   C6  every list of conventional commit types (a paragraph or list item
#       that mentions "conventional" and at least two `type` code spans)
#       equals commit.conventional_types of `dotsteward context --json` on a
#       synthetic instance; with --required, at least one list exists
#   C7  the overlay precedence sentence (SC_PRECEDENCE_SENTENCE, whitespace
#       and emphasis free); the classification step: `dotsteward context
#       --json`, then an overlay mention, then references/classification.md,
#       all before the flow's first write (`update prepare`, `contribute
#       setup` or `contribute start`); references/classification.md equal to
#       tests/fixtures/skills-contract/classification.md; the hand-over skill
#       named in SKILL.md
#   C8  the framework upgrade step: SKILL.md names it and links
#       references/framework-upgrade.md; one file runs `gh release`, then
#       `nix flake update dotsteward`, then the gate
#   C9  skills/manifest.json is what tools/gen-skills-manifest.sh generates,
#       and lists exactly the expected skills
#   C10 plugins/dotsteward/skills holds exactly dotsteward-init; every
#       plugin manifest and marketplace entry that exists carries VERSION
#
# Settings (globals, set before calling a check):
#   SC_REPO_ROOT  framework root whose skills, LICENSE, VERSION and plugin
#                 files are checked (default: DS_REPO_ROOT)
#   SC_CLI        the CLI asked by C5 and C6 (default: DS_REPO_ROOT's
#                 cli/dotsteward)
# The privacy scan (C1), the canonical classification reference (C7) and the
# generator (C9) always come from DS_REPO_ROOT, the framework under test.
#
# Every check appends findings "C<n> <where>: <message>" to SC_FINDINGS and
# never exits; sc_assert_clean fails the test with all of them.
#
# Entry points of the per-skill tests:
#   sc_check_framework_skill NAME --handover SKILL [--require-conventional-types]
#                            [--framework-upgrade]
#       C1-C7 (and C8) for SC_REPO_ROOT/skills/NAME
#   sc_check_plugin_skill NAME
#       C1-C6 for SC_REPO_ROOT/plugins/dotsteward/skills/NAME
#   sc_check_manifest ROOT NAME...   C9
#   sc_check_plugin ROOT             C10

SC_REPO_ROOT=${SC_REPO_ROOT:-$DS_REPO_ROOT}
SC_CLI=${SC_CLI:-$DS_REPO_ROOT/cli/dotsteward}
SC_FINDINGS=()
SC_PRECEDENCE_SENTENCE='On the gate, publish preconditions, decision ownership, secrets, force push and the local-only rule, this skill wins over any overlay.'
SC_CANONICAL_CLASSIFICATION=$DS_REPO_ROOT/tests/fixtures/skills-contract/classification.md
SC_PLUGIN_SKILLS=(dotsteward-init)

declare -gA _SC_HELP_TEXT=() _SC_HELP_STATUS=()
_SC_CONVENTIONAL_TYPES=""
_SC_CONVENTIONAL_STATE=""
_SC_INSTANCE=""

# sc_reset: forgets the findings and the cached CLI answers, and removes the
# synthetic instance of the previous C6 run.
sc_reset() {
  if [[ -n $_SC_INSTANCE ]]; then
    rm -rf -- "$_SC_INSTANCE"
    _SC_INSTANCE=""
  fi
  SC_FINDINGS=()
  _SC_HELP_TEXT=()
  _SC_HELP_STATUS=()
  _SC_CONVENTIONAL_TYPES=""
  _SC_CONVENTIONAL_STATE=""
}

# sc_finding ID WHERE MESSAGE
sc_finding() {
  SC_FINDINGS+=("$1 $2: $3")
}

sc_assert_clean() {
  ((${#SC_FINDINGS[@]} == 0)) && return 0
  local message
  message="${#SC_FINDINGS[@]} skill contract findings:"
  local finding
  for finding in "${SC_FINDINGS[@]}"; do
    message+=$'\n'"  $finding"
  done
  ds_fail "$message"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# _sc_markdown_files DIR: SKILL.md, then references/*.md sorted, as paths
# relative to DIR (only the regular files that exist).
_sc_markdown_files() {
  local dir=$1 file
  [[ -f $dir/SKILL.md && ! -L $dir/SKILL.md ]] && printf '%s\n' SKILL.md
  if [[ -d $dir/references ]]; then
    while IFS= read -r file; do
      printf 'references/%s\n' "$file"
    done < <(find "$dir/references" -mindepth 1 -maxdepth 1 -type f -name '*.md' -printf '%f\n' | LC_ALL=C sort)
  fi
}

# _sc_frontmatter FILE KEY: prints the value of the top-level KEY of the YAML
# frontmatter (plain, single- or double-quoted, or a > / | block scalar,
# folded into one line). Status 1: KEY absent; 2: no frontmatter;
# 3: frontmatter not closed.
_sc_frontmatter() {
  awk -v key="$2" '
    function unquote(v) {
      if (v ~ /^".*"$/) { v = substr(v, 2, length(v) - 2); gsub(/\\"/, "\"", v); return v }
      if (v ~ /^\047.*\047$/) { v = substr(v, 2, length(v) - 2); gsub(/\047\047/, "\047", v); return v }
      return v
    }
    { sub(/\r$/, "") }
    NR == 1 { if ($0 !~ /^---[ \t]*$/) { status = 2; exit } next }
    /^---[ \t]*$/ { closed = 1; exit }
    block {
      if ($0 ~ /^[ \t]+/ || $0 ~ /^[ \t]*$/) {
        line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line)
        if (line != "") value = value (value == "" ? "" : " ") line
        next
      }
      block = 0
    }
    index($0, key ":") == 1 {
      found = 1
      v = substr($0, length(key) + 2); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      if (v ~ /^[>|][-+]?$/) { block = 1; value = ""; next }
      value = unquote(v)
    }
    END {
      if (status) exit status
      if (!closed) exit 3
      if (!found) exit 1
      print value
    }
  ' "$1"
}

# _sc_char_count TEXT: the number of characters (not bytes) of TEXT.
_sc_char_count() {
  printf '%s' "$1" | LC_ALL=C.UTF-8 wc -m | tr -d ' '
}

# _sc_fenced_lines FILE: "LINE<TAB>TEXT" for every line inside a fenced
# block (``` or ~~~), backslash continuations joined into the first line.
# Status 4 when a fence is not closed.
_sc_fenced_lines() {
  awk '
    function fence_of(s,   c, n) {
      sub(/^[ \t]+/, "", s)
      c = substr(s, 1, 1)
      if (c != "`" && c != "~") return ""
      n = 0
      while (substr(s, n + 1, 1) == c) n++
      return n >= 3 ? substr(s, 1, n) : ""
    }
    { sub(/\r$/, "") }
    !open {
      f = fence_of($0)
      if (f != "") { open = f }
      next
    }
    {
      f = fence_of($0)
      rest = $0; sub(/^[ \t]+/, "", rest); rest = substr(rest, length(f) + 1)
      if (f != "" && substr(f, 1, 1) == substr(open, 1, 1) && length(f) >= length(open) && rest ~ /^[ \t]*$/) {
        if (buffer != "") print start "\t" buffer
        buffer = ""; open = ""
        next
      }
      line = $0
      if (buffer == "") start = NR
      if (line ~ /\\$/) { buffer = buffer substr(line, 1, length(line) - 1) " "; next }
      print start "\t" buffer line
      buffer = ""
    }
    END { if (open != "") exit 4 }
  ' "$1"
}

# _sc_units FILE: "LINE<TAB>TEXT" for every paragraph or list item outside
# fenced blocks, its lines joined with spaces.
_sc_units() {
  awk '
    function flush() { if (text != "") print start "\t" text; text = "" }
    { sub(/\r$/, "") }
    /^[ \t]*(```|~~~)/ { flush(); fenced = !fenced; next }
    fenced { next }
    /^[ \t]*$/ { flush(); next }
    /^[ \t]*([-*+]|[0-9]+[.)])[ \t]/ || /^#/ { flush() }
    { if (text == "") start = NR; text = text (text == "" ? "" : " ") $0 }
    END { flush() }
  ' "$1"
}

# _sc_help WORD...: runs `SC_CLI WORD... --help` once per word list and
# caches its status and output (stdout and stderr) under _sc_help_key WORD....
_sc_help() {
  local key status=0 output
  key=$(_sc_help_key "$@")
  [[ -n ${_SC_HELP_STATUS[$key]+set} ]] && return 0
  output=$("$SC_CLI" "$@" --help </dev/null 2>&1) || status=$?
  _SC_HELP_TEXT[$key]=$output
  _SC_HELP_STATUS[$key]=$status
}

_sc_help_key() {
  if (($#)); then
    printf '%s' "$*"
  else
    printf '%s' '(dotsteward)'
  fi
}

# _sc_has_word TEXT WORD: WORD appears in TEXT, not as part of a longer
# option or command name.
_sc_has_word() {
  local rest=$1 word=$2 before after previous=""
  while [[ $rest == *"$word"* ]]; do
    before=$previous${rest%%"$word"*}
    after=${rest#*"$word"}
    if [[ ! ${before: -1} =~ [A-Za-z0-9_-] && ! ${after:0:1} =~ [A-Za-z0-9_-] ]]; then
      return 0
    fi
    previous=${word: -1}
    rest=$after
  done
  return 1
}

# _sc_check_command WHERE TOKEN...: checks one dotsteward invocation (the
# tokens after the program name).
_sc_check_command() {
  local where=$1
  shift
  local tokens=("$@") i=0 n=$# token flag sub step="" text
  # Global options before the command.
  while ((i < n)) && [[ ${tokens[i]} == -* ]]; do
    token=${tokens[i]}
    case $token in
      --instance)
        i=$((i + 2))
        continue
        ;;
      --instance=*) ;;
      --*)
        flag=${token%%=*}
        _sc_help
        if ! _sc_has_word "${_SC_HELP_TEXT['(dotsteward)']}" "$flag"; then
          sc_finding C5 "$where" "\`dotsteward\`: $flag is not in its --help"
        fi
        ;;
    esac
    i=$((i + 1))
  done
  ((i < n)) || return 0
  sub=${tokens[i]}
  [[ $sub =~ ^[a-z][a-z0-9-]*$ ]] || return 0
  _sc_help "$sub"
  if [[ ${_SC_HELP_STATUS[$sub]} != 0 ]]; then
    sc_finding C5 "$where" "\`dotsteward $sub\`: no such command (\`dotsteward $sub --help\` exited ${_SC_HELP_STATUS[$sub]})"
    return 0
  fi
  text=${_SC_HELP_TEXT[$sub]}
  i=$((i + 1))
  if ((i < n)) && [[ ${tokens[i]} =~ ^[a-z][a-z0-9-]*$ ]]; then
    step=${tokens[i]}
    if ! _sc_has_word "$text" "$step"; then
      sc_finding C5 "$where" "\`dotsteward $sub $step\`: $step is not in \`dotsteward $sub --help\`"
      return 0
    fi
    _sc_help "$sub" "$step"
    if [[ ${_SC_HELP_STATUS["$sub $step"]} == 0 ]]; then
      text+=$'\n'${_SC_HELP_TEXT["$sub $step"]}
    fi
    i=$((i + 1))
  fi
  for ((; i < n; i++)); do
    token=${tokens[i]}
    [[ $token == -- ]] && break
    token=${token#[\[\"\']}
    [[ $token =~ ^(--[a-z0-9][a-z0-9-]*) ]] || continue
    flag=${BASH_REMATCH[1]}
    if ! _sc_has_word "$text" "$flag"; then
      sc_finding C5 "$where" "\`dotsteward $sub${step:+ $step}\`: $flag is not in its --help"
    fi
  done
}

# _sc_check_fragment WHERE TEXT: one simple command of a fenced line.
_sc_check_fragment() {
  local where=$1 fragment=$2 tokens=() i=0 n
  read -r -a tokens <<<"$fragment" || true
  n=${#tokens[@]}
  # Skip what may precede a command name.
  while ((i < n)); do
    case ${tokens[i]} in
      if | then | do | while | until | else | elif | exec | command | nohup | time | '!' | '{' | env | sudo | '$')
        i=$((i + 1))
        ;;
      timeout)
        i=$((i + 1))
        while ((i < n)) && [[ ${tokens[i]} == -* || ${tokens[i]} =~ ^[0-9]+[smhd]?$ ]]; do
          i=$((i + 1))
        done
        ;;
      *)
        if [[ ${tokens[i]} =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
          i=$((i + 1))
        else
          break
        fi
        ;;
    esac
  done
  ((i < n)) || return 0
  case ${tokens[i]} in
    dotsteward | .dotsteward/cli.sh | */.dotsteward/cli.sh) ;;
    *) return 0 ;;
  esac
  _sc_check_command "$where" "${tokens[@]:i+1}"
}

# ---------------------------------------------------------------------------
# C1-C8: one skill directory
# ---------------------------------------------------------------------------

sc_check_frontmatter() {
  local dir=$1 name skill value status desc count
  name=$(basename "$dir")
  skill=$dir/SKILL.md
  if [[ ! -f $skill || -L $skill ]]; then
    sc_finding C1 "$name" "SKILL.md is missing or not a regular file"
    return 0
  fi
  status=0
  value=$(_sc_frontmatter "$skill" name) || status=$?
  case $status in
    2)
      sc_finding C1 "$name/SKILL.md" "no frontmatter (the first line must be ---)"
      return 0
      ;;
    3)
      sc_finding C1 "$name/SKILL.md" "frontmatter is not closed by a --- line"
      return 0
      ;;
  esac
  if [[ $value != "$name" ]]; then
    sc_finding C1 "$name/SKILL.md" "frontmatter name [$value] differs from the directory name [$name]"
  fi
  if [[ ! $name =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    sc_finding C1 "$name/SKILL.md" "name [$name] is not lowercase words joined by single hyphens"
  elif ((${#name} > 64)); then
    sc_finding C1 "$name/SKILL.md" "name [$name] is longer than 64 characters"
  fi
  desc=$(_sc_frontmatter "$skill" description) || desc=""
  if [[ -z $desc ]]; then
    sc_finding C1 "$name/SKILL.md" "frontmatter description is missing or empty"
    return 0
  fi
  count=$(_sc_char_count "$desc")
  if ((count > 1024)); then
    sc_finding C1 "$name/SKILL.md" "description has $count characters (at most 1024)"
  fi
  if [[ $desc =~ \<[A-Za-z/] ]]; then
    sc_finding C1 "$name/SKILL.md" "description contains an XML tag"
  fi
}

# sc_check_tree DIR: no symlinks, and no privacy finding of the generic
# scanner rules (run on a copy, so the result does not depend on the
# repository around DIR).
sc_check_tree() {
  local dir=$1 name link copy output line status=0
  name=$(basename "$dir")
  while IFS= read -r link; do
    sc_finding C1 "$name/${link#./}" "symlinks are not allowed in a skill"
  done < <(cd "$dir" && find . -type l | LC_ALL=C sort)
  copy=$(mktemp -d "${TMPDIR:-/tmp}/dotsteward-skill-scan.XXXXXX")
  cp -R "$dir/." "$copy/"
  git -C "$copy" init -q
  output=$(cd "$copy" && "$DS_REPO_ROOT/cli/dotsteward" scan --tree --redact 2>&1) || status=$?
  rm -rf -- "$copy"
  ((status == 0)) && return 0
  local reported=0
  while IFS= read -r line; do
    [[ -n $line && $line != '[dotsteward] '* ]] || continue
    sc_finding C1 "$name" "privacy: $line"
    reported=1
  done <<<"$output"
  if ((!reported)); then
    sc_finding C1 "$name" "privacy scan failed (exit $status): ${output//$'\n'/ }"
  fi
}

sc_check_openai_yaml() {
  local dir=$1 name yaml key value values
  name=$(basename "$dir")
  yaml=$dir/agents/openai.yaml
  if [[ ! -f $yaml || -L $yaml ]]; then
    sc_finding C2 "$name" "agents/openai.yaml is missing or not a regular file"
    return 0
  fi
  # KEY<TAB>VALUE for the keys of the top-level interface mapping.
  values=$(awk '
    { sub(/\r$/, "") }
    /^[^ \t#]/ { inside = ($0 ~ /^interface:[ \t]*$/); next }
    inside && /^[ \t]+[A-Za-z_][A-Za-z0-9_]*:/ {
      line = $0; sub(/^[ \t]+/, "", line)
      key = line; sub(/:.*/, "", key)
      v = substr(line, length(key) + 2); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
      print key "\t" v
    }
  ' "$yaml")
  for key in display_name short_description default_prompt; do
    value=$(awk -F '\t' -v k="$key" '$1 == k { print substr($0, length(k) + 2); exit }' <<<"$values")
    if [[ -z $value ]]; then
      sc_finding C2 "$name/agents/openai.yaml" "interface.$key is missing or empty"
    elif [[ $key == default_prompt ]] && ! _sc_has_word "$value" "\$$name"; then
      sc_finding C2 "$name/agents/openai.yaml" "interface.default_prompt does not mention \$$name"
    fi
  done
}

sc_check_license() {
  local dir=$1 name license=$SC_REPO_ROOT/LICENSE
  name=$(basename "$dir")
  if ! grep -qx 'MIT License' "$license" 2>/dev/null ||
    ! grep -q '^Copyright (c) [0-9-]* dotsteward contributors$' "$license"; then
    sc_finding C3 "framework LICENSE" "not the MIT license of dotsteward contributors"
  fi
  if [[ ! -f $dir/LICENSE || -L $dir/LICENSE ]]; then
    sc_finding C3 "$name" "LICENSE is missing or not a regular file"
  elif ! cmp -s "$license" "$dir/LICENSE"; then
    sc_finding C3 "$name/LICENSE" "differs from the framework LICENSE"
  fi
}

sc_check_references() {
  local dir=$1 name entry file mention line text count=0
  name=$(basename "$dir")
  if [[ -d $dir/references && ! -L $dir/references ]]; then
    while IFS= read -r entry; do
      if [[ -f $dir/references/$entry && ! -L $dir/references/$entry && $entry == *.md ]]; then
        count=$((count + 1))
      else
        sc_finding C4 "$name/references/$entry" "references/ holds only *.md files"
      fi
    done < <(find "$dir/references" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
  fi
  if ((count == 0)); then
    sc_finding C4 "$name" "references/ is missing or has no *.md file"
  fi
  # Mentions of this skill's references (a references/ preceded by a path
  # character belongs to another skill or another tree).
  while IFS= read -r file; do
    while IFS=: read -r line text; do
      while [[ $text =~ (^|[^A-Za-z0-9_./-])references/([A-Za-z0-9_.-]+\.md) ]]; do
        mention=${BASH_REMATCH[2]}
        text=${text#*"${BASH_REMATCH[0]}"}
        if [[ ! -f $dir/references/$mention ]]; then
          sc_finding C4 "$name/$file:$line" "references/$mention is mentioned but does not exist"
        fi
      done
    done < <(grep -n 'references/' "$dir/$file" || true)
  done < <(_sc_markdown_files "$dir")
  [[ -f $dir/SKILL.md ]] || return 0
  while IFS= read -r file; do
    [[ $file == references/* ]] || continue
    if ! grep -Eq "(^|[^A-Za-z0-9_./-])${file//./\\.}([^A-Za-z0-9_-]|$)" "$dir/SKILL.md"; then
      sc_finding C4 "$name/$file" "not linked from SKILL.md"
    fi
  done < <(_sc_markdown_files "$dir")
}

sc_check_cli() {
  local dir=$1 name file line text status lines fragment fragments=()
  name=$(basename "$dir")
  while IFS= read -r file; do
    status=0
    lines=$(_sc_fenced_lines "$dir/$file") || status=$?
    if ((status != 0)); then
      sc_finding C5 "$name/$file" "unclosed fenced block"
    fi
    [[ -n $lines ]] || continue
    while IFS=$'\t' read -r line text; do
      # Comments end the command line; terminators and substitutions split it
      # into simple commands.
      text=$(sed -E 's/(^|[[:space:]])#.*$//' <<<"$text")
      text=${text//\$(/$'\n'}
      # shellcheck disable=SC2016 # a literal backtick, not an expansion
      text=$(tr '|;&()`' '\n' <<<"$text")
      mapfile -t fragments <<<"$text"
      for fragment in "${fragments[@]}"; do
        _sc_check_fragment "$name/$file:$line" "$fragment"
      done
    done <<<"$lines"
  done < <(_sc_markdown_files "$dir")
}

# _sc_cli_conventional_types: the CLI's types, sorted, one line; status 1
# with a finding text in _SC_CONVENTIONAL_STATE on failure.
_sc_cli_conventional_types() {
  case $_SC_CONVENTIONAL_STATE in
    ok) return 0 ;;
    '') ;;
    *) return 1 ;;
  esac
  local instance remote output status=0
  instance=$(mktemp -d "${TMPDIR:-/tmp}/dotsteward-skill-instance.XXXXXX")
  _SC_INSTANCE=$instance
  cp "$DS_REPO_ROOT/tests/fixtures/skills-contract/instance/workstation.toml" "$instance/"
  remote=$(sed -n 's/^remote = "\(.*\)"$/\1/p' "$instance/workstation.toml")
  git -C "$instance" init -q
  git -C "$instance" remote add origin "$remote"
  git -C "$instance" add -A
  git -C "$instance" commit -q -m 'chore: initialize synthetic instance'
  output=$("$SC_CLI" --instance "$instance" context --json 2>&1 </dev/null) || status=$?
  if ((status != 0)); then
    _SC_CONVENTIONAL_STATE="\`dotsteward context --json\` failed on the synthetic instance (exit $status): ${output//$'\n'/ }"
    return 1
  fi
  _SC_CONVENTIONAL_TYPES=$(jq -r '.commit.conventional_types // [] | .[]' <<<"$output" 2>/dev/null | LC_ALL=C sort -u | tr '\n' ' ') || true
  _SC_CONVENTIONAL_TYPES=${_SC_CONVENTIONAL_TYPES% }
  if [[ -z $_SC_CONVENTIONAL_TYPES ]]; then
    _SC_CONVENTIONAL_STATE="\`dotsteward context --json\` has no commit.conventional_types"
    return 1
  fi
  _SC_CONVENTIONAL_STATE=ok
}

# _sc_set_difference "A..." "B...": words of A that are not in B.
_sc_set_difference() {
  comm -23 <(tr ' ' '\n' <<<"$1" | sed '/^$/d' | LC_ALL=C sort -u) \
    <(tr ' ' '\n' <<<"$2" | sed '/^$/d' | LC_ALL=C sort -u) | tr '\n' ' ' | sed 's/ $//'
}

sc_check_conventional_types() {
  local dir=$1 required=0 name file line text types found=0 missing extra message
  [[ ${2:-} == --required ]] && required=1
  name=$(basename "$dir")
  while IFS= read -r file; do
    while IFS=$'\t' read -r line text; do
      shopt -s nocasematch
      if [[ $text != *conventional* ]]; then
        shopt -u nocasematch
        continue
      fi
      shopt -u nocasematch
      # shellcheck disable=SC2016 # Markdown code spans, not expansions
      types=$(grep -oE '`[a-z]+`' <<<"$text" | tr -d '`' | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//') || true
      [[ $types == *' '* ]] || continue
      found=1
      if ! _sc_cli_conventional_types; then
        sc_finding C6 "$name" "$_SC_CONVENTIONAL_STATE"
        return 0
      fi
      [[ $types == "$_SC_CONVENTIONAL_TYPES" ]] && continue
      missing=$(_sc_set_difference "$_SC_CONVENTIONAL_TYPES" "$types")
      extra=$(_sc_set_difference "$types" "$_SC_CONVENTIONAL_TYPES")
      message="conventional commit types [$types] differ from the CLI [$_SC_CONVENTIONAL_TYPES]:"
      [[ -n $missing ]] && message+=" missing $missing"
      [[ -n $missing && -n $extra ]] && message+=";"
      [[ -n $extra ]] && message+=" extra $extra"
      sc_finding C6 "$name/$file:$line" "$message"
    done < <(_sc_units "$dir/$file")
  done < <(_sc_markdown_files "$dir")
  if ((required && !found)); then
    sc_finding C6 "$name" "no list of conventional commit types (expected one)"
  fi
}

sc_check_precedence() {
  local dir=$1 name flat
  name=$(basename "$dir")
  [[ -f $dir/SKILL.md ]] || return 0
  flat=$(tr -s '[:space:]' ' ' <"$dir/SKILL.md" | sed 's/\*\*//g; s/__//g')
  if [[ $flat != *"$SC_PRECEDENCE_SENTENCE"* ]]; then
    sc_finding C7 "$name/SKILL.md" "the overlay precedence sentence is missing"
  fi
}

# _sc_first_line FILE AFTER ERE: the first line number greater than AFTER
# whose text matches ERE (case-insensitive), or nothing. The ERE goes through
# the environment: awk -v would process its backslash escapes.
_sc_first_line() {
  re=$3 awk -v after="$2" 'NR > after && tolower($0) ~ ENVIRON["re"] { print NR; exit }' "$1"
}

sc_check_classification() {
  local dir=$1 handover=$2 name skill context overlay classification write
  name=$(basename "$dir")
  skill=$dir/SKILL.md
  if [[ ! -f $dir/references/classification.md ]]; then
    sc_finding C7 "$name/references/classification.md" "missing"
  elif ! cmp -s "$SC_CANONICAL_CLASSIFICATION" "$dir/references/classification.md"; then
    sc_finding C7 "$name/references/classification.md" \
      "differs from the canonical tests/fixtures/skills-contract/classification.md"
  fi
  [[ -f $skill ]] || return 0
  if ! grep -Eq "(^|[^A-Za-z0-9_-])$handover([^A-Za-z0-9_-]|$)" "$skill"; then
    sc_finding C7 "$name/SKILL.md" "does not hand over to $handover"
  fi
  context=$(_sc_first_line "$skill" 0 'dotsteward context --json')
  if [[ -z $context ]]; then
    sc_finding C7 "$name/SKILL.md" "\`dotsteward context --json\` is never run"
    return 0
  fi
  overlay=$(_sc_first_line "$skill" "$context" 'overlay')
  if [[ -z $overlay ]]; then
    sc_finding C7 "$name/SKILL.md" "no overlay step after \`dotsteward context --json\`"
    return 0
  fi
  classification=$(_sc_first_line "$skill" "$((overlay - 1))" 'references/classification\.md')
  if [[ -z $classification ]]; then
    sc_finding C7 "$name/SKILL.md" "no classification step (references/classification.md) after the overlay step"
    return 0
  fi
  write=$(_sc_first_line "$skill" 0 '(dotsteward|cli\.sh) +(update +prepare|contribute +(setup|start))')
  if [[ -n $write ]] && ((write < classification)); then
    sc_finding C7 "$name/SKILL.md:$write" \
      "the first write (\`$(sed -n "${write}p" "$skill" | grep -oE '(update +prepare|contribute +(setup|start))' | head -n 1 | sed 's/^/dotsteward /')\`) comes before the classification step (references/classification.md)"
  fi
}

sc_check_framework_upgrade() {
  local dir=$1 name file release bump gate ok=0
  name=$(basename "$dir")
  [[ -f $dir/SKILL.md ]] || return 0
  if ! grep -qi 'framework upgrade' "$dir/SKILL.md"; then
    sc_finding C8 "$name/SKILL.md" "does not name the framework upgrade step"
  fi
  if ! grep -q 'references/framework-upgrade\.md' "$dir/SKILL.md"; then
    sc_finding C8 "$name/SKILL.md" "does not link references/framework-upgrade.md"
  fi
  while IFS= read -r file; do
    release=$(_sc_first_line "$dir/$file" 0 'gh +release +(list|view)')
    [[ -n $release ]] || continue
    bump=$(_sc_first_line "$dir/$file" "$release" 'nix +flake +update +dotsteward')
    [[ -n $bump ]] || continue
    gate=$(_sc_first_line "$dir/$file" "$bump" '(dotsteward|cli\.sh) +gate')
    if [[ -n $gate ]]; then
      ok=1
      break
    fi
  done < <(_sc_markdown_files "$dir")
  if ((!ok)); then
    sc_finding C8 "$name" "no file runs \`gh release\` (the release notes), then \`nix flake update dotsteward\`, then the gate, in this order"
  fi
}

sc_check_framework_skill() {
  local name=$1 handover=dotsteward-contribute conventional="" upgrade=0 dir
  shift
  while (($#)); do
    case $1 in
      --handover)
        handover=${2:?--handover requires a skill name}
        shift 2
        ;;
      --require-conventional-types)
        conventional=--required
        shift
        ;;
      --framework-upgrade)
        upgrade=1
        shift
        ;;
      *)
        printf 'sc_check_framework_skill: unknown option: %s\n' "$1" >&2
        return 1
        ;;
    esac
  done
  dir=$SC_REPO_ROOT/skills/$name
  if [[ ! -d $dir || -L $dir ]]; then
    sc_finding C1 "$name" "no skill directory at skills/$name"
    return 0
  fi
  sc_check_frontmatter "$dir"
  sc_check_tree "$dir"
  sc_check_openai_yaml "$dir"
  sc_check_license "$dir"
  sc_check_references "$dir"
  sc_check_cli "$dir"
  sc_check_conventional_types "$dir" $conventional
  sc_check_precedence "$dir"
  sc_check_classification "$dir" "$handover"
  if ((upgrade)); then
    sc_check_framework_upgrade "$dir"
  fi
}

sc_check_plugin_skill() {
  local name=$1 dir
  dir=$SC_REPO_ROOT/plugins/dotsteward/skills/$name
  if [[ ! -d $dir || -L $dir ]]; then
    sc_finding C1 "$name" "no skill directory at plugins/dotsteward/skills/$name"
    return 0
  fi
  sc_check_frontmatter "$dir"
  sc_check_tree "$dir"
  sc_check_openai_yaml "$dir"
  sc_check_license "$dir"
  sc_check_references "$dir"
  sc_check_cli "$dir"
  sc_check_conventional_types "$dir"
}

# ---------------------------------------------------------------------------
# C9, C10: the framework tree
# ---------------------------------------------------------------------------

# sc_check_manifest ROOT NAME...: ROOT/skills/manifest.json is current and
# lists exactly NAME....
sc_check_manifest() {
  local root=$1 output status=0 names expected
  shift
  output=$(bash "$DS_REPO_ROOT/tools/gen-skills-manifest.sh" --check --root "$root" 2>&1) || status=$?
  if ((status != 0)); then
    output=${output##*ERROR: }
    sc_finding C9 "skills/manifest.json" "${output#skills/manifest.json }"
    return 0
  fi
  names=$(jq -r '.skills[].name' "$root/skills/manifest.json" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
  expected=$(printf '%s\n' "$@" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
  if [[ $names != "$expected" ]]; then
    sc_finding C9 "skills/manifest.json" "skills [$names] differ from the expected [$expected]"
  fi
}

sc_check_plugin() {
  local root=$1 dir=$1/plugins/dotsteward/skills entries expected version file versions value
  if [[ ! -d $dir ]]; then
    sc_finding C10 "plugins/dotsteward/skills" "missing"
  else
    entries=$(find "$dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
    expected=$(printf '%s\n' "${SC_PLUGIN_SKILLS[@]}" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
    if [[ $entries != "$expected" ]]; then
      sc_finding C10 "plugins/dotsteward/skills" "holds [$entries], expected exactly [$expected]"
    fi
  fi
  version=$(tr -d '[:space:]' <"$root/VERSION")
  for file in plugins/dotsteward/.claude-plugin/plugin.json plugins/dotsteward/.codex-plugin/plugin.json \
    .claude-plugin/marketplace.json .agents/plugins/marketplace.json; do
    [[ -e $root/$file ]] || continue
    if ! jq -e . "$root/$file" >/dev/null 2>&1; then
      sc_finding C10 "$file" "not valid JSON"
      continue
    fi
    if [[ $file == */plugin.json ]]; then
      versions=$(jq -r '.version // ""' "$root/$file")
    else
      versions=$(jq -r '.plugins[]? | .version // empty' "$root/$file")
      [[ -n $versions ]] || continue
    fi
    while IFS= read -r value; do
      if [[ $value != "$version" ]]; then
        sc_finding C10 "$file" "version [$value] differs from VERSION [$version]"
      fi
    done <<<"$versions"
  done
}
