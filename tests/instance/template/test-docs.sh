# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # bash -c scripts take their arguments as $1, $2
# The generic instance documents of template/: README.md,
# AGENTS.md, components/README.md, agent/overlays/README.md and
# tests/README.md describe what each part of an instance is for, name the
# commands and files they document correctly, and pass the framework's
# command-name rule for fenced shell blocks.
# shellcheck source=tests/instance/template/helpers.sh
source "$DS_REPO_ROOT/tests/instance/template/helpers.sh"

# contains_all FILE NEEDLE...: FILE contains every fixed string NEEDLE.
contains_all() {
  local file=$1 text needle
  shift
  text=$(<"$tpl/$file")
  for needle in "$@"; do
    assert_contains "$text" "$needle" "$file"
  done
}

for doc in README.md AGENTS.md components/README.md agent/overlays/README.md tests/README.md; do
  head -n 1 "$tpl/$doc" | grep -q '^# ' || ds_fail "$doc does not start with a title"
done

# README.md: the entry points and every top-level part of the instance.
contains_all README.md \
  './bootstrap.sh --profile' './rebuild.sh --profile' '--switch' './rollback.sh' \
  './update.sh prepare' './update.sh validate' './update.sh publish' './update.sh status' \
  'workstation.toml' 'versions.lock.json' 'flake.nix' 'flake.lock' 'home.nix' 'home/AGENTS.md' \
  'components/' 'agent/skills.lock.json' 'agent/overlays/' 'local-maintained-files/' 'tests/' \
  '.dotsteward/' 'dotsteward-maintain' 'dotsteward-update' 'dotsteward-contribute'

# AGENTS.md: the rules for coding agents working in the instance.
contains_all AGENTS.md \
  'dotsteward context --json' 'dotsteward-maintain' 'dotsteward-update' 'dotsteward-contribute' \
  '.dotsteward/' 'bootstrap.sh' 'git add -A' 'dotsteward gate'
# The gate comes before every push, the first push of a new instance
# included, in the order the dotsteward-init skill follows: gate, then
# `git push -u origin main` for the first push, `dotsteward update publish`
# afterwards.
contains_all AGENTS.md 'first push' 'git push -u origin main' 'dotsteward update publish' 'never force-push'
first_push=$(tr '\n' ' ' <"$tpl/AGENTS.md" | tr -s ' ')
[[ $first_push == *"before every push, the first push of a new instance included"* ]] ||
  ds_fail "AGENTS.md does not put the gate before the first push of a new instance"

# components/README.md: enabling the example and writing a component.
contains_all components/README.md \
  'components/example/default.nix.disabled' 'components/example-term/default.nix' \
  '[components.example-term]' 'agent_tools.example-term' 'dotsteward sync' 'docs/writing-components.md' \
  'package.nix'

# agent/overlays/README.md: the overlay of each framework skill, exactly the
# skills workstation.toml accepts overlays for.
skills=$(jq -r '.properties.skills.properties.overlays.propertyNames.enum[]' "$DS_REPO_ROOT/schema/workstation.schema.json")
[[ -n $skills ]] || ds_fail "the schema lists no framework skill"
while IFS= read -r skill; do
  contains_all agent/overlays/README.md "agent/overlays/$skill.md"
done <<<"$skills"
contains_all agent/overlays/README.md '[skills.overlays]'

# tests/README.md: how instance tests plug into the gate's static step.
contains_all tests/README.md \
  '[gate]' 'static = ["tests/' 'dotsteward static' 'instance-static' \
  'DOTSTEWARD_INSTANCE_ROOT' 'DOTSTEWARD_SANDBOX' 'DOTSTEWARD_STATIC_HELPER' 'fail'

# Every `dotsteward <subcommand>` a document quotes exists in the CLI (init
# is the command that creates an instance).
while IFS= read -r subcommand; do
  [[ -f $DS_REPO_ROOT/cli/commands/$subcommand.sh ]] ||
    ds_fail "the template documents name 'dotsteward $subcommand', which the CLI does not have"
done < <(cd "$tpl" && grep -rhoE '`dotsteward [a-z][a-z-]*' README.md AGENTS.md components/README.md \
  agent/overlays/README.md tests/README.md | awk '{print $2}' | LC_ALL=C sort -u | grep -vx init)

# The command-name rule of the framework static check, over the template.
fw=$DS_TEST_ROOT/framework
mkdir -p "$fw"
tar -C "$DS_REPO_ROOT" --exclude=.git --exclude=__pycache__ -cf - cli privacy schema modules tests/static template VERSION |
  tar -C "$fw" -xf -
assert_exit 0 bash -c 'cd "$1" && ./cli/dotsteward static --sandbox --only command-names' _ "$fw"
