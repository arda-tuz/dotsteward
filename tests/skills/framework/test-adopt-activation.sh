# shellcheck shell=bash
# shellcheck disable=SC2153 # DS_REPO_ROOT comes from tests/lib/harness.sh
# What the framework skills tell an agent about activating system-level
# components on an adopted machine, and where durable lessons go:
#   A1  dotsteward-maintain, section 5: on an adopt-mode profile the rebuild
#       does not install a new or changed system-level component; the user
#       runs `dotsteward --instance <path> install --profile <profile>
#       --component <name>` (sudo, in their own terminal, which need not be
#       in the instance checkout) after the commit and before the rebuild,
#       which otherwise stops with "required command not found"
#   A2  dotsteward-update, section 5: the local activation of an update on an
#       adopt-mode profile names the same command, with --instance, for a
#       raised deb floor or a new system-level requirement, before the
#       rebuild
#   A3  every framework skill keeps durable workflow lessons in versioned
#       text (the framework skill through dotsteward-contribute, or the
#       instance overlay), never in an agent's own memory store
# shellcheck source=tests/skills/lib/contract.sh
source "$DS_REPO_ROOT/tests/skills/lib/contract.sh"

findings=()

finding() {
  findings+=("$1 $2: $3")
}

# section FILE HEADING: the lines of the "## HEADING..." section of FILE.
section() {
  awk -v heading="## $2" 'index($0, heading) == 1 { open = 1; print; next } open && /^## / { exit } open { print }' "$1"
}

# units_of TEXT: one line per paragraph or list item of the Markdown TEXT.
units_of() {
  local file
  file=$(mktemp)
  printf '%s\n' "$1" >"$file"
  _sc_units "$file" | cut -f 2-
  rm -f -- "$file"
}

# unit_with UNITS NEEDLE...: the first unit that contains every NEEDLE
# (fixed strings, case-insensitive).
unit_with() {
  local units=$1 unit needle ok
  shift
  while IFS= read -r unit; do
    ok=1
    for needle in "$@"; do
      [[ ${unit,,} == *"${needle,,}"* ]] || {
        ok=0
        break
      }
    done
    if ((ok)); then
      printf '%s\n' "$unit"
      return 0
    fi
  done <<<"$units"
  return 1
}

skills=$SC_REPO_ROOT/skills
maintain=$skills/dotsteward-maintain/SKILL.md
update=$skills/dotsteward-update/SKILL.md

# A1: maintain, section 5.
units=$(units_of "$(section "$maintain" "5.")")
unit_with "$units" "adopt" "dotsteward --instance" "install --profile" "--component" "before" "rebuild" >/dev/null ||
  finding A1 dotsteward-maintain/SKILL.md \
    "section 5 does not run install --component, with --instance, before the rebuild on an adopt-mode profile"
unit_with "$units" "adopt" "required command not found" >/dev/null ||
  finding A1 dotsteward-maintain/SKILL.md \
    "section 5 does not name the rebuild failure of a missing system-level component"
unit_with "$units" "adopt" "sudo" "terminal" >/dev/null ||
  finding A1 dotsteward-maintain/SKILL.md \
    "section 5 does not hand the sudo step of install --component to the user's terminal"

# A2: update, section 5 (local activation).
units=$(units_of "$(section "$update" "5.")")
unit_with "$units" "adopt" "deb" "floor" "dotsteward --instance" "install --profile" "--component" "rebuild" >/dev/null ||
  finding A2 dotsteward-update/SKILL.md \
    "section 5 does not bring a raised deb floor to an adopt-mode machine with install --component, with --instance, before the rebuild"

# A3: durable lessons stay in versioned text.
for name in dotsteward-maintain dotsteward-update dotsteward-contribute; do
  units=$(_sc_units "$skills/$name/SKILL.md" | cut -f 2-)
  unit_with "$units" "lesson" "memory" "overlay" "dotsteward-contribute" >/dev/null ||
    finding A3 "$name/SKILL.md" \
      "durable lessons are not routed to the framework skill or the overlay instead of agent memory"
done

if ((${#findings[@]})); then
  message="${#findings[@]} adopt activation findings:"
  for item in "${findings[@]}"; do
    message+=$'\n'"  $item"
  done
  ds_fail "$message"
fi
