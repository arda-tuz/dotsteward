#!/usr/bin/env bash
# Regenerates references/catalog.md of the dotsteward-init plugin skill, the
# catalog table the skill offers when it creates a new instance (SPEC 9.7),
# from the README of each catalog component.
#
# Usage: tools/gen-init-catalog.sh [--check] [--root DIR]
#
# DIR (default: the framework checkout holding this script) is the framework
# root. Every directory of DIR/modules/components is a catalog component,
# in the order of CATALOG_ORDER in DIR/cli/python/dotsteward_cli/config.py
# (the order of `dotsteward init`), the others sorted after them. Each
# component's README.md gives its section of the catalog:
#
#   - the first line, which must be the heading "# <name>";
#   - the summary: the first paragraph after the heading;
#   - the enable block: the first ```toml block before the first level-2
#     heading that holds the line "[components.<name>]";
#   - the methods table: the first table of the section "## Methods", else
#     "## Install", else "## What it installs".
#
# A README without one of them is refused and nothing is written. Without
# --check the file is written (atomically, mode 0644) when its bytes change.
# --check only compares and exits 1 when the file is missing or stale.
set -Eeuo pipefail

script_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=cli/lib/lib.sh
source "$script_root/cli/lib/lib.sh"

catalog_rel=plugins/dotsteward/skills/dotsteward-init/references/catalog.md

usage() {
  sed -n '6s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"
}

check=0
root=$script_root
while (($#)); do
  case $1 in
    --check)
      check=1
      shift
      ;;
    --root)
      (($# >= 2)) || die "--root requires a directory"
      root=$2
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown option: $1 ($(usage))" ;;
  esac
done

components_dir=$root/modules/components
config_py=$root/cli/python/dotsteward_cli/config.py
catalog=$root/$catalog_rel
[[ -d $components_dir ]] || die "no catalog directory: $components_dir"
[[ -f $config_py ]] || die "no CLI configuration module: $config_py"
[[ -d $(dirname "$catalog") ]] || die "no skill references directory: $(dirname "$catalog")"

# The canonical order: CATALOG_ORDER = ("a", "b", ...) on one line.
order_line=$(sed -n 's/^CATALOG_ORDER = (\(.*\))$/\1/p' "$config_py")
[[ -n $order_line ]] || die "cannot read CATALOG_ORDER from cli/python/dotsteward_cli/config.py"
known=()
while IFS= read -r name; do
  [[ -n $name ]] && known+=("$name")
done < <(tr ',' '\n' <<<"$order_line" | sed -E 's/^[[:space:]]*"([^"]*)"[[:space:]]*$/\1/')

present=()
while IFS= read -r -d '' path; do
  [[ ! -L $path ]] || die "modules/components/${path##*/}: a component directory must not be a symlink"
  present+=("${path##*/}")
done < <(find "$components_dir" -mindepth 1 -maxdepth 1 -type d -print0 | LC_ALL=C sort -z)
((${#present[@]})) || die "no catalog components in $components_dir"

names=()
for name in "${known[@]}"; do
  for entry in "${present[@]}"; do
    if [[ $entry == "$name" ]]; then
      names+=("$name")
      break
    fi
  done
done
for entry in "${present[@]}"; do
  listed=0
  for name in "${known[@]}"; do
    [[ $entry == "$name" ]] && listed=1 && break
  done
  ((listed)) || names+=("$entry")
done

# component_section NAME README: prints the catalog section of NAME. Status
# 2: the first line is not "# NAME"; 3: no summary paragraph; 4: no enable
# block; 5: no methods table.
component_section() {
  awk -v name="$1" '
    function fence(s) { return s ~ /^[ \t]*(```|~~~)/ }
    { sub(/\r$/, "") }
    NR == 1 {
      if ($0 != "# " name) { status = 2; exit }
      state = "summary"
      next
    }
    state == "summary" {
      if ($0 ~ /^[ \t]*$/) { if (summary != "") state = "lead"; next }
      if ($0 ~ /^#/ || fence($0)) { state = "lead" }
      else { line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line); summary = summary (summary == "" ? "" : " ") line; next }
    }
    state == "lead" {
      if (block != "") {
        block = block "\n" $0
        if (fence($0)) {
          if (has_enable && enable == "") enable = block
          block = ""; has_enable = 0
        } else if ($0 == "[components." name "]") {
          has_enable = 1
        }
        next
      }
      if (lead_fence) { if (fence($0)) lead_fence = 0; next }
      if ($0 ~ /^```toml[ \t]*$/) { block = $0; next }
      if (fence($0)) { lead_fence = 1; next }
    }
    state == "sections" && fence($0) { in_fence = !in_fence; next }
    in_fence { next }
    /^## / {
      state = "sections"
      heading = $0; sub(/[ \t]+$/, "", heading)
      section = ""
      if (heading == "## Methods") section = "methods"
      else if (heading == "## Install") section = "install"
      else if (heading == "## What it installs") section = "installs"
      next
    }
    state == "sections" && section != "" {
      if ($0 ~ /^\|/) {
        if (!(section in done)) tables[section] = tables[section] (tables[section] == "" ? "" : "\n") $0
        next
      }
      if (tables[section] != "") done[section] = 1
    }
    END {
      if (status) exit status
      if (summary == "") exit 3
      if (enable == "") exit 4
      table = tables["methods"]
      if (table == "") table = tables["install"]
      if (table == "") table = tables["installs"]
      if (split(table, rows, "\n") < 3) exit 5
      printf "## %s\n\n%s\n\n%s\n\n%s\n", name, summary, enable, table
    }
  ' "$2"
}

document="# Catalog

Generated by \`tools/gen-init-catalog.sh\` of the framework repository from the
README of each catalog component (\`modules/components/<name>/README.md\`); do
not edit it by hand.

These are the components a new instance can enable, in the order
\`dotsteward init\` uses. Pass the chosen names to \`--components\` (comma
separated). Each component installs with its default method unless the user
picks another one from its table: \`--method COMPONENT=METHOD\` for every
platform, or \`--method-platform COMPONENT=linux:METHOD,darwin:METHOD\` for one
method per platform. A method must be supported on every system of the
instance (\`--systems\`), or the first build names the supported ones.

The TOML block of each component is its README's example of the component's
table in \`workstation.toml\`; \`init\` writes that table from the chosen names
and methods. Options (an \`options\` table) are not set by \`init\`: change them
afterwards through the dotsteward-maintain skill of the instance.
"
for name in "${names[@]}"; do
  readme=$components_dir/$name/README.md
  where=modules/components/$name/README.md
  [[ -f $readme && ! -L $readme ]] || die "$where is missing or not a regular file"
  status=0
  section=$(component_section "$name" "$readme") || status=$?
  case $status in
    0) ;;
    2) die "$where: the first line must be the heading \"# $name\"" ;;
    3) die "$where: no summary paragraph after the heading" ;;
    4) die "$where: no \`\`\`toml block with [components.$name] before the first level-2 heading" ;;
    5) die "$where: no methods table under \"## Methods\", \"## Install\" or \"## What it installs\"" ;;
    *) die "$where: cannot be read (awk exited $status)" ;;
  esac
  document+=$'\n'$section$'\n'
done

if [[ -f $catalog && $(<"$catalog") == "${document%$'\n'}" && $(tail -c 1 "$catalog" | od -An -tx1 | tr -d ' ') == 0a ]]; then
  log "$catalog_rel is up to date (${#names[@]} components)"
  exit 0
fi
if ((check)); then
  if [[ -f $catalog ]]; then
    die "$catalog_rel is stale; run tools/gen-init-catalog.sh"
  fi
  die "$catalog_rel is missing; run tools/gen-init-catalog.sh"
fi

temp=$(mktemp "$(dirname "$catalog")/.catalog.md.XXXXXX")
trap 'rm -f -- "$temp"' EXIT
printf '%s' "$document" >"$temp"
chmod 0644 "$temp"
mv -f -- "$temp" "$catalog"
trap - EXIT
log "wrote $catalog_rel (${#names[@]} components)"
