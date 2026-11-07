# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# A component another machine enabled: the question, and the tag that keeps it out of the
# generation of this machine until the answer. A component for other machines is no question.
# shellcheck source=tests/incoming/helpers.sh
source "$DS_REPO_ROOT/tests/incoming/helpers.sh"

machine_up laptop1
machine_up laptop2

add_component_on() {
  local clone
  clone=$(clone_of laptop1)
  mkdir -p "$clone/components/$1" "$clone/hosts"
  printf 'schema_version = 1\n' >"$clone/hosts/laptop1.toml"
  printf '{ ... }: { }\n' >"$clone/components/$1/default.nix"
  printf '\n[components.%s]\nenable = true\n%s\n' "$1" "${2:-}" >>"$clone/workstation.toml"
  git -C "$clone" add -A
  git -C "$clone" commit -q -m $'feat: a component\n\nDotsteward-Machine: laptop1'
  git -C "$clone" push -q origin main
}

nix_tags() {
  assert_exit 0 ds "$1" skills effective --json
  jq -c .nix_tags <<<"$DS_STDOUT"
}

# A commit of this machine that is not published and touches the same file says nothing about
# the component of another machine: only a commit that brings the component does.
clone2=$(clone_of laptop2)
up_to_date laptop1
add_component_on early-tool
up_to_date laptop2
assert_eq 'component:early-tool' "$(waiting laptop2)"
printf '\n# a note of this machine\n' >>"$clone2/workstation.toml"
git -C "$clone2" add -A
git -C "$clone2" commit -q -m "chore: a note"
assert_eq 'component:early-tool' "$(waiting laptop2)"
git -C "$clone2" reset -q --hard HEAD~1
assert_exit 0 ds laptop2 incoming answer component:early-tool --install

# Ask later: left out of every command and of the generation, nothing stored.
add_component_on example-tool
up_to_date laptop2
assert_exit 0 ds laptop2 incoming list --json
assert_json - '.items[0].id == "component:example-tool" and .items[0].kind == "component" and .items[0].by == "laptop1"' <<<"$DS_STDOUT"
assert_eq '["example-tool"]' "$(skipped laptop2 components)"
assert_exit 0 ds laptop2 skills effective --json
assert_eq incoming "$(jq -r '.reasons["component:example-tool"]' <<<"$DS_STDOUT")"
assert_eq '["machine:laptop2","no:example-tool"]' "$(nix_tags laptop2)"
assert_contains "$(ask_on_tty laptop2 l incoming)" 'component example-tool (new) - machine laptop1'
assert_eq '["machine:laptop2","no:example-tool"]' "$(nix_tags laptop2)"

# The machine that enabled it: nothing to ask, nothing left out.
assert_eq '' "$(waiting laptop1)"
assert_eq '[]' "$(skipped laptop1 components)"

# Install: it counts from now on, and the next upgrade or rebuild activates it.
assert_exit 0 ds laptop2 incoming answer component:example-tool --install
assert_contains "$DS_STDOUT$DS_STDERR" 'next'
assert_eq '[]' "$(skipped laptop2 components)"
assert_eq '["machine:laptop2"]' "$(nix_tags laptop2)"
assert_eq '' "$(waiting laptop2)"

# Never: the tag comes from the host file, so the gates of every machine evaluate it.
up_to_date laptop1
add_component_on other-tool
up_to_date laptop2
assert_exit 0 ds laptop2 incoming answer component:other-tool --never
assert_contains "$(remote_file hosts/laptop2.toml)" 'other-tool'
assert_eq '["other-tool"]' "$(skipped laptop2 components)"
assert_exit 0 ds laptop2 skills effective --json
assert_eq declined "$(jq -r '.reasons["component:other-tool"]' <<<"$DS_STDOUT")"
assert_eq '["machine:laptop2","no:other-tool"]' "$(nix_tags laptop2)"
assert_eq '' "$(waiting laptop2)"

# Never on a component others need: Nix says no, so the answer does not stand and nothing
# reaches the gates of the other machines.
up_to_date laptop1
add_component_on needed-tool
up_to_date laptop2
cat >"$DS_TEST_ROOT/bin/nix" <<STUB
#!$BASH
printf 'error:\n  Failed assertions:\n  - dotsteward: component needed-tool is left out on this machine, and other-app needs it\n' >&2
exit 1
STUB
chmod 0755 "$DS_TEST_ROOT/bin/nix"
before=$(remote_tip)
assert_exit 1 ds laptop2 incoming answer component:needed-tool --never
assert_contains "$DS_STDERR" 'component needed-tool is left out on this machine, and other-app needs it'
assert_eq "$before" "$(remote_tip)"
assert_eq 'component:needed-tool' "$(waiting laptop2)"

# Nix fails for another reason: that says nothing about the answer, and the message does not claim so.
cat >"$DS_TEST_ROOT/bin/nix" <<STUB
#!$BASH
printf 'error: cannot connect to the store\n' >&2
exit 1
STUB
assert_exit 1 ds laptop2 incoming answer component:needed-tool --never
assert_contains "$DS_STDERR" 'could not check this answer with Nix: error: cannot connect to the store'
assert_not_contains "$DS_STDERR" 'does not evaluate'
assert_eq "$before" "$(remote_tip)"
assert_eq 'component:needed-tool' "$(waiting laptop2)"

# An older pin has no such output: nothing to say, the answer stands. Asked for with the framework
# of an override, Nix gets it too.
cat >"$DS_TEST_ROOT/bin/nix" <<STUB
#!$BASH
printf '%s\n' "\$*" >"$DS_TEST_ROOT/nix-args"
printf "error: flake 'git+file:///x' does not provide attribute 'hostConfigurations'\n" >&2
exit 1
STUB
with_override() {
  DOTSTEWARD_FRAMEWORK_OVERRIDE=git+file:///example/framework ds "$@"
}
assert_exit 0 with_override laptop2 incoming answer component:needed-tool --never
assert_contains "$(<"$DS_TEST_ROOT/nix-args")" '--override-input dotsteward git+file:///example/framework'
assert_contains "$(<"$DS_TEST_ROOT/nix-args")" '#hostConfigurations.laptop2.activationPackage.drvPath'
assert_contains "$(remote_file hosts/laptop2.toml)" 'needed-tool'
rm -f -- "$DS_TEST_ROOT/bin/nix"

# For another machine, or a tag this one does not carry: no question, no tag, left out.
up_to_date laptop1
add_component_on only-there 'machines = ["laptop1"]'
up_to_date laptop1
add_component_on tagged-tool 'tags = ["nvidia"]'
up_to_date laptop2
assert_eq '' "$(waiting laptop2)"
assert_exit 0 ds laptop2 skills effective --json
assert_eq machines "$(jq -r '.reasons["component:only-there"]' <<<"$DS_STDOUT")"
assert_eq tags "$(jq -r '.reasons["component:tagged-tool"]' <<<"$DS_STDOUT")"
assert_eq '["machine:laptop2","no:needed-tool","no:other-tool"]' "$(nix_tags laptop2)"
assert_eq '' "$(waiting laptop1)"
assert_eq '["only-there","tagged-tool"]' "$(skipped laptop2 components | jq -c 'map(select(. != "other-tool" and . != "needed-tool"))')"

# M1: installed and not active yet: the generation of this machine says no:, so nothing expects it
# until the rebuild, which builds it.
up_to_date laptop1
add_component_on pending-tool
up_to_date laptop2
state_activation=$(state_of laptop2)/current/activation.json
mkdir -p "$(dirname "$state_activation")"
jq -n '{schema_version: "1.0", tags: ["machine:laptop2", "no:pending-tool"], tags_sha256: "x"}' >"$state_activation"
assert_exit 0 ds laptop2 incoming answer component:pending-tool --install
assert_exit 0 ds laptop2 skills effective --json
assert_eq not-activated "$(jq -r '.reasons["component:pending-tool"]' <<<"$DS_STDOUT")"
assert_not_contains "$(jq -c .nix_tags <<<"$DS_STDOUT")" 'no:pending-tool'
assert_eq '' "$(waiting laptop2)"
jq -n '{schema_version: "1.0", tags: ["machine:laptop2"], tags_sha256: "x"}' >"$state_activation"
assert_not_contains "$(skipped laptop2 components)" 'pending-tool'

# M2: what a component this machine runs needs arrives with the tree, without a question, and
# the report names both. M2b: both new: Install of the one takes the other along.
up_to_date laptop1
set_requires() {
  local clone manifest
  clone=$(clone_of laptop1)
  manifest=$clone/.dotsteward/manifest.x86_64-linux.json
  jq --arg name "$1" --argjson requires "$2" '
    if any(.components[]?; .name == $name) then
      (.components[] | select(.name == $name)).requires = $requires
    else .components += [{name: $name, requires: $requires}] end' "$manifest" >"$manifest.new"
  mv -- "$manifest.new" "$manifest"
}
add_component_on running-tool
up_to_date laptop2
assert_exit 0 ds laptop2 incoming answer component:running-tool --install
up_to_date laptop1
set_requires running-tool '["new-dep"]'
add_component_on new-dep
up_to_date laptop2
assert_eq '' "$(waiting laptop2)"
assert_not_contains "$(nix_tags laptop2)" 'no:new-dep'
assert_exit 0 ds laptop2 skills effective --json
assert_json - '.requires.arriving == [{"component": "new-dep", "needed_by": "running-tool"}]' <<<"$DS_STDOUT"
assert_exit 0 ds laptop2 incoming
assert_contains "$DS_STDERR" 'new-dep comes with this tree: running-tool needs it'
assert_json "$(state_of laptop2)/review.json" '[.items[] | select(.code == "component-needed" and .component == "new-dep")] | length == 1'
up_to_date laptop1
add_component_on pair-base
up_to_date laptop1
set_requires pair-top '["pair-base"]'
add_component_on pair-top
up_to_date laptop2
assert_eq 'component:pair-base component:pair-top' "$(waiting laptop2)"
assert_exit 0 ds laptop2 incoming list --json
assert_json - '(.items[] | select(.id == "component:pair-top") | .needs) == ["pair-base"]' <<<"$DS_STDOUT"
assert_contains "$(ask_on_tty laptop2 $'l\nl' incoming)" 'needed by pair-top'
assert_exit 0 ds laptop2 incoming answer component:pair-top --install
assert_eq '' "$(waiting laptop2)"

# M3: what this machine declined and another component of it now needs: it is out too, on this
# machine, and the person here is told. No other machine hears of it.
up_to_date laptop1
add_component_on lone
up_to_date laptop2
assert_exit 0 ds laptop2 incoming answer component:lone --never
up_to_date laptop1
set_requires running-tool '["lone"]'
git -C "$(clone_of laptop1)" add -A
git -C "$(clone_of laptop1)" commit -q -m $'feat: needs lone\n\nDotsteward-Machine: laptop1'
git -C "$(clone_of laptop1)" push -q origin main
up_to_date laptop2
assert_exit 0 ds laptop2 skills effective --json
assert_eq requires "$(jq -r '.reasons["component:running-tool"]' <<<"$DS_STDOUT")"
assert_json - '.requires.unmet == [{"component": "running-tool", "needs": "lone", "why": "declined"}]' <<<"$DS_STDOUT"
assert_contains "$(jq -c .nix_tags <<<"$DS_STDOUT")" 'no:running-tool'
assert_exit 0 ds laptop2 incoming
assert_contains "$DS_STDERR" 'running-tool is left out: it needs lone, which this machine declined'
assert_json "$(state_of laptop2)/review.json" '[.items[] | select(.code == "requires-unmet" and .component == "running-tool")] | length == 1'
up_to_date laptop1
assert_not_contains "$(nix_tags laptop1)" 'no:running-tool'

# A reinstall under the same name brings back what is for it, without a question.
up_to_date laptop1
rm -rf -- "$(state_of laptop1)" "$(home_of laptop1)"
mkdir -p "$(state_of laptop1)" "$(home_of laptop1)/.agents/skills" "$(home_of laptop1)/.claude/skills" "$(home_of laptop1)/.codex/skills"
assert_exit 0 agents laptop1 install --skip-validation
assert_eq '' "$(waiting laptop1)"
assert_exit 0 ds laptop1 skills effective --json
assert_not_contains "$(jq -c .skip.components <<<"$DS_STDOUT")" 'only-there'
