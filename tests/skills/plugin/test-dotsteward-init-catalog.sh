# shellcheck shell=bash
# shellcheck disable=SC2153 # DS_REPO_ROOT comes from tests/lib/harness.sh
# shellcheck disable=SC2016 # literal Markdown code spans in single quotes
# references/catalog.md of plugins/dotsteward/skills/dotsteward-init is
# generated from the catalog READMEs by tools/gen-init-catalog.sh: the
# committed file is current, lists every catalog component in the
# canonical order with its summary, its enable block and its methods table,
# and the generator's --check catches a README change, rewrites the file
# without --check, and refuses a README it cannot read.

generator=$DS_REPO_ROOT/tools/gen-init-catalog.sh
catalog_path=plugins/dotsteward/skills/dotsteward-init/references/catalog.md
catalog=$DS_REPO_ROOT/$catalog_path
[[ -f $generator ]] || ds_fail "missing tools/gen-init-catalog.sh"
[[ -f $catalog ]] || ds_fail "missing $catalog_path"

# The committed catalog is what the generator writes.
assert_exit 0 bash "$generator" --check

# Every catalog component, in the order of CATALOG_ORDER in the CLI.
order=$(sed -n 's/^CATALOG_ORDER = (\(.*\))$/\1/p' "$DS_REPO_ROOT/cli/python/dotsteward_cli/config.py" |
  tr ',' '\n' | tr -d '" ' | sed '/^$/d' | tr '\n' ' ')
[[ -n $order ]] || ds_fail "cannot read CATALOG_ORDER"
headings=$(sed -n 's/^## \(.*\)$/\1/p' "$catalog" | tr '\n' ' ')
assert_eq "$order" "$headings" "catalog.md sections"
for name in $order; do
  readme=$DS_REPO_ROOT/modules/components/$name/README.md
  [[ -f $readme ]] || ds_fail "missing modules/components/$name/README.md"
  assert_contains "$(<"$catalog")" "[components.$name]" "catalog.md has the enable block of $name"
  # The first line of the README's summary paragraph is in the catalog.
  summary=$(awk 'NR > 1 && NF { print; exit }' "$readme")
  assert_contains "$(tr '\n' ' ' <"$catalog")" "$summary" "catalog.md has the summary of $name"
done
assert_contains "$(<"$catalog")" "tools/gen-init-catalog.sh" "catalog.md says how it is generated"

# A copy of the inputs: the README of each component, the CLI's catalog
# order and the generated file.
root=$DS_TEST_ROOT/framework
mkdir -p "$root/cli/python/dotsteward_cli" "$(dirname "$root/$catalog_path")"
cp "$DS_REPO_ROOT/cli/python/dotsteward_cli/config.py" "$root/cli/python/dotsteward_cli/"
cp "$catalog" "$root/$catalog_path"
for name in $order; do
  mkdir -p "$root/modules/components/$name"
  cp "$DS_REPO_ROOT/modules/components/$name/README.md" "$root/modules/components/$name/"
done
assert_exit 0 bash "$generator" --check --root "$root"

# A changed summary makes the catalog stale; --check changes nothing.
readme=$root/modules/components/shell/README.md
awk 'NR == 3 { print "A synthetic summary line for the drift test."; print; next } { print }' "$readme" >"$readme.new"
mv "$readme.new" "$readme"
before=$(<"$root/$catalog_path")
assert_exit 1 bash "$generator" --check --root "$root"
assert_contains "$DS_STDERR" "stale" "--check reports the stale catalog"
assert_contains "$DS_STDERR" "tools/gen-init-catalog.sh" "--check names the generator"
assert_eq "$before" "$(<"$root/$catalog_path")" "--check leaves the catalog as it was"

# Without --check the catalog is rewritten, then current.
assert_exit 0 bash "$generator" --root "$root"
assert_contains "$(<"$root/$catalog_path")" "A synthetic summary line for the drift test." "the new summary"
assert_file_mode "$root/$catalog_path" 644
assert_exit 0 bash "$generator" --check --root "$root"

# A component outside CATALOG_ORDER follows the known ones.
mkdir -p "$root/modules/components/a-synthetic"
cat >"$root/modules/components/a-synthetic/README.md" <<'EOF'
# a-synthetic

A synthetic component of the generator test.

Enable it in `workstation.toml`:

```toml
[components.a-synthetic]
enable = true
```

## Methods

| Method | Platforms |
| --- | --- |
| `nix` | Linux, darwin |
EOF
assert_exit 0 bash "$generator" --root "$root"
headings=$(sed -n 's/^## \(.*\)$/\1/p' "$root/$catalog_path" | tr '\n' ' ')
assert_eq "${order}a-synthetic " "$headings" "an unknown component comes last"
rm -rf "$root/modules/components/a-synthetic"
assert_exit 0 bash "$generator" --root "$root"

# A README the generator cannot read is refused, and the catalog stays.
before=$(<"$root/$catalog_path")
readme=$root/modules/components/herdr/README.md
cp "$readme" "$DS_TEST_ROOT/herdr-README.md"
sed -i '/^| /d' "$readme"
assert_exit 1 bash "$generator" --root "$root"
assert_contains "$DS_STDERR" "modules/components/herdr/README.md" "the refusal names the README"
assert_contains "$DS_STDERR" "methods table" "the refusal names the missing methods table"
assert_eq "$before" "$(<"$root/$catalog_path")" "a refused run leaves the catalog as it was"

cp "$DS_TEST_ROOT/herdr-README.md" "$readme"
sed -i '1s/.*/# not-herdr/' "$readme"
assert_exit 1 bash "$generator" --root "$root"
assert_contains "$DS_STDERR" "heading" "a README whose title is not the component is refused"

cp "$DS_TEST_ROOT/herdr-README.md" "$readme"
sed -i '/^\[components.herdr\]$/d' "$readme"
assert_exit 1 bash "$generator" --root "$root"
assert_contains "$DS_STDERR" "[components.herdr]" "a README without the enable block is refused"

# Preselection: the line "Preselected for new instances on: `SYSTEM`[, ...]."
# of a README reaches the component's section of the catalog; the five
# components that install a vendor DEB from GitHub releases carry it for
# x86_64-linux, the other catalog components do not, and the catalog says
# when a preselected component starts selected.
cp "$DS_TEST_ROOT/herdr-README.md" "$readme"
assert_exit 0 bash "$generator" --root "$root"
assert_contains "$(tr '\n' ' ' <"$catalog")" 'Preselected for new instances on:" is part of the default choice' \
  "catalog.md explains preselection"
# preselected_of CATALOG: the names of the sections that carry the line.
preselected_of() {
  awk '/^## / { name = substr($0, 4) } $0 == "Preselected for new instances on: `x86_64-linux`." { print name }' "$1" |
    tr '\n' ' '
}
assert_eq "pdfcraft gridcraft wordcraft deckcraft craft-anything " "$(preselected_of "$catalog")" \
  "the preselected components of the catalog"
for name in pdfcraft gridcraft wordcraft deckcraft craft-anything; do
  awk -v n="## $name" '$0 == n { open = 1; next } open && /^## / { exit } open' "$catalog" |
    grep -qxF 'Preselected for new instances on: `x86_64-linux`.' ||
    ds_fail "the catalog section of $name lacks its preselection line"
done

# The line on another README reaches its section; a malformed or repeated
# line, or a system outside x86_64-linux and aarch64-darwin, is refused.
readme=$root/modules/components/herdr/README.md
awk '/^```toml/ { fence = 1 } { print } fence && /^```$/ && !done { print ""; print "Preselected for new instances on: `x86_64-linux`, `aarch64-darwin`."; done = 1 }' \
  "$DS_TEST_ROOT/herdr-README.md" >"$readme"
assert_exit 0 bash "$generator" --root "$root"
awk '$0 == "## herdr" { open = 1; next } open && /^## / { exit } open' "$root/$catalog_path" |
  grep -qxF 'Preselected for new instances on: `x86_64-linux`, `aarch64-darwin`.' ||
  ds_fail "the preselection line of herdr does not reach its section"
for bad in 'Preselected for new instances on: x86_64-linux.' \
  'Preselected for new instances on: `riscv64-linux`.' \
  'Preselected for new instances on: `x86_64-linux`'; do
  awk -v bad="$bad" '/^```toml/ { fence = 1 } { print } fence && /^```$/ && !done { print ""; print bad; done = 1 }' \
    "$DS_TEST_ROOT/herdr-README.md" >"$readme"
  assert_exit 1 bash "$generator" --root "$root"
  assert_contains "$DS_STDERR" "preselection line" "a malformed preselection line is refused: $bad"
done
awk '/^```toml/ { fence = 1 } { print } fence && /^```$/ && !done { print ""; print "Preselected for new instances on: `x86_64-linux`."; print "Preselected for new instances on: `x86_64-linux`."; done = 1 }' \
  "$DS_TEST_ROOT/herdr-README.md" >"$readme"
assert_exit 1 bash "$generator" --root "$root"
assert_contains "$DS_STDERR" "preselection line" "a repeated preselection line is refused"
