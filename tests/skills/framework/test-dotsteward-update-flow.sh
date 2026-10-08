# shellcheck shell=bash
# shellcheck disable=SC2153 # DS_REPO_ROOT comes from tests/lib/harness.sh
# The update flow of skills/dotsteward-update, beyond the generic
# contract C1-C8 of test-dotsteward-update.sh:
#   U1  references/ holds exactly classification.md, framework-upgrade.md,
#       sources-and-hashes.md and update-contract.md
#   U2  the fenced commands of SKILL.md run, in this order: a temporary
#       dotsteward-update.* directory, a clone of instance.remote with
#       --reference-if-able <instance.path> --dissociate, update prepare
#       --official-sources-only, pins latest --out, sync --nix, git add -A,
#       the gate, git commit with commit.update_subject, update publish,
#       update status --json, removal of the temporary directory
#   U3  the candidate table has the statuses update, review, held, manual
#       and error; nixpkgs and Home Manager move together; the framework
#       upgrade runs only when the framework row is review; the report
#       carries step_seconds; the settings buffer is never touched
#   U4  references/framework-upgrade.md: gh release list, gh release view,
#       the tag in flake.nix, nix flake update dotsteward, bootstrap.sh and
#       .dotsteward/cli.sh refreshed from the new template/, sync, then the
#       gate through the clone's launcher; a red gate keeps the old tag
#   U5  the skill never activates, pushes or hard-codes a system or a state
#       path: no rebuild --switch, no git push, no x86_64-linux or
#       aarch64-darwin literal (the current system comes from
#       .platform.system), no .local/state path
# shellcheck source=tests/skills/lib/contract.sh
source "$DS_REPO_ROOT/tests/skills/lib/contract.sh"

skill_dir=$SC_REPO_ROOT/skills/dotsteward-update
findings=()

finding() {
  findings+=("$1 $2: $3")
}

# fenced FILE: "LINE<TAB>TEXT" of the fenced lines of FILE (see contract.sh).
fenced() {
  _sc_fenced_lines "$1" 2>/dev/null || true
}

# first_after LINES AFTER ERE: the first line number greater than AFTER of
# the "LINE<TAB>TEXT" records in LINES whose text matches ERE. The ERE goes
# through the environment: awk -v would process its backslash escapes.
first_after() {
  re=$3 awk -F '\t' -v after="$2" '$1 > after && substr($0, length($1) + 2) ~ ENVIRON["re"] { print $1; exit }' <<<"$1"
}

# expect_order ID FILE LINES LABEL ERE [LABEL ERE]...: each ERE matches a
# fenced line after the line of the previous one.
expect_order() {
  local id=$1 file=$2 lines=$3 after=0 label re at
  shift 3
  while (($#)); do
    label=$1 re=$2
    shift 2
    at=$(first_after "$lines" "$after" "$re")
    if [[ -z $at ]]; then
      finding "$id" "$file" "no fenced command for [$label] after line $after"
      return 0
    fi
    after=$at
  done
}

if [[ ! -f $skill_dir/SKILL.md ]]; then
  ds_fail "skills/dotsteward-update/SKILL.md is missing"
fi
skill=$skill_dir/SKILL.md
upgrade=$skill_dir/references/framework-upgrade.md

# U1: the reference set.
references=$(find "$skill_dir/references" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')
assert_eq "classification.md framework-upgrade.md sources-and-hashes.md update-contract.md " "$references" \
  "U1 skills/dotsteward-update/references"

# U2: the fenced flow of SKILL.md.
skill_lines=$(fenced "$skill")
# shellcheck disable=SC2016 # regular expressions with a literal $work
expect_order U2 SKILL.md "$skill_lines" \
  'temporary directory' 'mktemp -d .*dotsteward-update\.X+' \
  'clone of the instance' 'git clone .*--reference-if-able .*--dissociate' \
  'update prepare' '(dotsteward|cli\.sh) +update +prepare +--official-sources-only' \
  'pins latest --out' '(dotsteward|cli\.sh) +pins +latest .*--out' \
  'sync --nix' '(dotsteward|cli\.sh) +sync +--nix' \
  'git add -A' 'git add -A' \
  'gate' '(dotsteward|cli\.sh) +gate' \
  'git commit' 'git commit' \
  'update publish' '(dotsteward|cli\.sh) +update +publish' \
  'update status --json' '(dotsteward|cli\.sh) +update +status +--json' \
  'cleanup' 'rm -rf -- "\$work"'
clone=$(grep -E 'git clone' <<<"$skill_lines" | head -n 1)
[[ $clone == *instance_path* || $clone == *'.instance.path'* ]] ||
  finding U2 SKILL.md "the clone does not reference the instance path from the context"
grep -q '\.instance\.path' <<<"$skill_lines" || finding U2 SKILL.md "the instance path is not read from .instance.path"
grep -q '\.instance\.remote' <<<"$skill_lines" || finding U2 SKILL.md "the clone URL is not read from .instance.remote"
grep -q '\.commit\.update_subject' <<<"$skill_lines" ||
  finding U2 SKILL.md "the commit subject is not read from .commit.update_subject"

# U3: candidate statuses, nixpkgs with Home Manager, framework row, report.
for status in update review held manual error; do
  grep -Eq "^\| \`$status\` \|" "$skill" || finding U3 SKILL.md "the candidate table has no \`$status\` row"
done
units=$(_sc_units "$skill")
grep -Ei 'nixpkgs' <<<"$units" | grep -Ei 'home.manager' | grep -qi 'together' ||
  finding U3 SKILL.md "nixpkgs and Home Manager are not moved together"
# shellcheck disable=SC2016 # Markdown code spans, not expansions
grep -F '`framework`' <<<"$units" | grep -F '`review`' | grep -qF 'references/framework-upgrade.md' ||
  finding U3 SKILL.md "the framework upgrade is not tied to the \`framework\` row in \`review\`"
grep -q 'step_seconds' "$skill" || finding U3 SKILL.md "the report does not carry step_seconds"
grep -q 'settings\.buffer_dir' "$skill" || finding U3 SKILL.md "the settings buffer (settings.buffer_dir) is not named"

# U4: the framework upgrade reference.
if [[ -f $upgrade ]]; then
  upgrade_lines=$(fenced "$upgrade")
  expect_order U4 references/framework-upgrade.md "$upgrade_lines" \
    'gh release list' 'gh +release +list' \
    'gh release view' 'gh +release +view' \
    'tag in flake.nix' 'flake\.nix' \
    'nix flake update dotsteward' 'nix +flake +update +dotsteward' \
    'refresh bootstrap.sh' 'template/bootstrap\.sh' \
    'refresh .dotsteward/cli.sh' 'template/\.dotsteward/cli\.sh' \
    'sync' '(dotsteward|cli\.sh) +sync' \
    'gate through the launcher' '\./\.dotsteward/cli\.sh +gate'
  grep -qi 'old tag' "$upgrade" || finding U4 references/framework-upgrade.md "a red gate does not keep the old tag"
else
  finding U4 references/framework-upgrade.md "missing"
fi

# U5: no activation, no push, no system or state path literals.
while IFS= read -r file; do
  lines=$(fenced "$skill_dir/$file")
  if grep -Eq '(dotsteward|cli\.sh) +rebuild .*--switch' <<<"$lines"; then
    finding U5 "$file" "a fenced command activates a generation (rebuild --switch)"
  fi
  if grep -Eq 'git +push' <<<"$lines"; then
    finding U5 "$file" "a fenced command pushes (publish pushes)"
  fi
  if grep -Eq 'x86_64-linux|aarch64-darwin' "$skill_dir/$file"; then
    finding U5 "$file" "names a system literally (use .platform.system)"
  fi
  if grep -q '\.local/state' "$skill_dir/$file"; then
    finding U5 "$file" "hard-codes a state path (use update status --json)"
  fi
done < <(_sc_markdown_files "$skill_dir")
grep -q '\.platform\.system' "$skill_dir/references/sources-and-hashes.md" 2>/dev/null ||
  finding U5 references/sources-and-hashes.md "the current system is not read from .platform.system"

if ((${#findings[@]})); then
  message="${#findings[@]} update flow findings:"
  for item in "${findings[@]}"; do
    message+=$'\n'"  $item"
  done
  ds_fail "$message"
fi
