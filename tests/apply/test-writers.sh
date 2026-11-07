# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# Who writes what (writer classes): on a machine that is not the producer the gate refuses, in
# every scope and before its memo, a pin value the base has (versions.lock.json, flake.lock, the
# pin fields and tool tables of the skill lock, the files of a third-party skill), and another
# machine's host file. It lets the same machine add a new pin, change machines, make a third-party
# skill its own, forget one, move generated_at and write its own host file. The producer may move
# every pin, and without [hosts] producer nothing is guarded. apply names the way out.
# shellcheck source=tests/apply/helpers.sh
source "$DS_REPO_ROOT/tests/apply/helpers.sh"

lock=$up_inst/agent/skills.lock.json
# The shared tree: two machines, other-host the producer, pins in every lock.
mkdir -p "$up_inst/hosts" "$up_inst/agent/skills/third-skill"
printf 'schema_version = 1\n' >"$up_inst/hosts/example-host.toml"
printf 'schema_version = 1\n' >"$up_inst/hosts/other-host.toml"
set_toml hosts producer '"other-host"'
jq -n '{schema_version: "1.0", generated_at: "2026-01-01T00:00:00Z",
  agent_tools: {codex: {linux: {version: "1.0.0", sha256: "1111111111111111111111111111111111111111111111111111111111111111"}}}}' \
  >"$up_inst/versions.lock.json"
jq -n '{nodes: {nixpkgs: {locked: {rev: "1111111", narHash: "sha256-one", type: "github"}, original: {type: "github"}},
  root: {inputs: {nixpkgs: "nixpkgs"}}}, root: "root", version: 7}' >"$up_inst/flake.lock"
printf -- '---\nname: third-skill\ndescription: A skill of a third party.\n---\nUpstream text.\n' \
  >"$up_inst/agent/skills/third-skill/SKILL.md"
jq -n '{schema_version: "1.0", generated_at: "2026-01-01T00:00:00Z", layout: {canonical_user_directory: "~/.agents/skills"},
  release_tools: {example: {version: "1.0.0"}},
  skills: [{name: "third-skill", directory: "third-skill", source: "github:example/skills",
    revision: "2222222222222222222222222222222222222222", skill_sha256: "33", machines: ["example-host"]}]}' >"$lock"
git -C "$up_inst" add -A
git -C "$up_inst" commit -q -m "chore: two machines and their pins"
git -C "$up_inst" push -q origin HEAD:main

# json_edit FILE FILTER: FILTER over the JSON file FILE, in place.
json_edit() {
  jq "$2" "$1" >"$1.new"
  mv -- "$1.new" "$1"
}

# refused PATH SUBJECT: apply refuses the change with writer-class for PATH before any step after
# the guards of the gate, and the checkout goes back to the published tip.
refused() {
  clear_log
  assert_exit 1 apply -m "$2" --no-activate --publish
  assert_contains "$DS_STDERR" "writer-class"
  assert_contains "$DS_STDERR" "$1"
  assert_no_step '^static '
  apply_report '[.items[] | select(.code == "writer-class")] | length == 1'
  apply_report '.items[] | select(.code == "writer-class") | .run == "dotsteward host producer example-host"'
  apply_report ".items[] | select(.code == \"writer-class\") | .paths | index(\"$1\") != null"
  assert_eq "$(remote_oid)" "$(head_oid)" "nothing was committed"
  git -C "$up_inst" reset -q --hard HEAD
  git -C "$up_inst" clean -qfd
}

# allowed SUBJECT: apply publishes the change.
allowed() {
  assert_exit 0 apply -m "$1" --no-activate --publish
  assert_eq "$(remote_oid)" "$(head_oid)" "published"
  assert_eq "" "$(git -C "$up_inst" status --porcelain)"
}

# --- not the producer: the pins of the base stay --------------------------------------------------

json_edit "$up_inst/versions.lock.json" '.agent_tools.codex.linux.version = "2.0.0"'
refused versions.lock.json "chore: move codex"

json_edit "$up_inst/flake.lock" '.nodes.nixpkgs.locked.rev = "9999999"'
refused flake.lock "chore: move nixpkgs"

json_edit "$lock" '.skills[0].revision = "4444444444444444444444444444444444444444"'
refused agent/skills.lock.json "chore: move a third-party skill"

json_edit "$lock" '.release_tools.example.version = "2.0.0"'
refused agent/skills.lock.json "chore: move a release tool"

printf 'A local change.\n' >>"$up_inst/agent/skills/third-skill/SKILL.md"
refused agent/skills/third-skill/SKILL.md "docs: change a third-party skill"

printf 'tags = ["laptop"]\n' >>"$up_inst/hosts/other-host.toml"
refused hosts/other-host.toml "chore: tag the other machine"

# The gate itself refuses, in the update scope as well, and a passed record of the same tree
# (the memo) does not let it through.
json_edit "$up_inst/versions.lock.json" '.agent_tools.codex.linux.version = "2.0.0"'
git -C "$up_inst" add -A
tree=$(git -C "$up_inst" write-tree)
jq -n --arg tree "$tree" --arg root "$up_inst" '{schema_version: "1.1", result: "passed", tree_oid: $tree,
  base_oid: "0000000000000000000000000000000000000000", scope: "maintain", nix_version: "nix (Nix) 2.31.2",
  gate_version: "0.0.0", framework_override: null, denylist_sha256: null, root: $root,
  validated_at: "2026-01-01T00:00:00Z", total_seconds: 1, step_seconds: {}, log: ""}' \
  | jq --arg version "$(<"$fw/VERSION")" '.gate_version = $version' >"$up_validation"
for scope in maintain update; do
  clear_log
  assert_exit 1 "$fw/cli/dotsteward" --instance "$up_inst" gate --scope "$scope" --expected-base "$(remote_oid)"
  assert_contains "$DS_STDERR" "writer-class: versions.lock.json"
  assert_not_contains "$DS_STDOUT$DS_STDERR" "already passed the gate"
done
git -C "$up_inst" reset -q --hard HEAD

# --- not the producer: what any machine may write ----------------------------------------------------

json_edit "$up_inst/versions.lock.json" '.agent_tools["example-cli"] = {linux: {version: "1.0.0"}} | .generated_at = "2026-02-02T00:00:00Z"'
json_edit "$up_inst/flake.lock" '.nodes["example-input"] = {locked: {rev: "5555555", type: "github"}, original: {type: "github"}}
  | .nodes.root.inputs["example-input"] = "example-input"'
json_edit "$lock" '.release_tools["new-tool"] = {version: "1.0.0"} | .generated_at = "2026-02-02T00:00:00Z"'
allowed "feat: add example-cli with its first pins"

json_edit "$lock" '.skills[0].machines = ["example-host", "other-host"]'
printf 'tags = ["desk"]\n' >>"$up_inst/hosts/example-host.toml"
allowed "chore: the skill on both machines"

# skills track --own: the copy becomes this instance's own and no longer follows upstream.
printf 'My own text.\n' >>"$up_inst/agent/skills/third-skill/SKILL.md"
json_edit "$lock" '.skills[0].revision = "same-as-instance-checkout" | .skills[0].skill_sha256 = "66"'
allowed "feat(skills): make third-skill our own"

# A third-party skill this machine adds, and its forget.
mkdir -p "$up_inst/agent/skills/fourth-skill"
printf -- '---\nname: fourth-skill\ndescription: Another skill.\n---\nText.\n' >"$up_inst/agent/skills/fourth-skill/SKILL.md"
json_edit "$lock" '.skills += [{name: "fourth-skill", directory: "fourth-skill", source: "github:example/more",
  revision: "7777777777777777777777777777777777777777", skill_sha256: "77"}]'
allowed "feat(skills): add fourth-skill"
rm -rf -- "$up_inst/agent/skills/fourth-skill"
json_edit "$lock" '.skills |= map(select(.name != "fourth-skill"))'
allowed "chore(skills): forget fourth-skill"

# --- the producer moves every pin; without a producer nothing is guarded --------------------------
# The producer of the base decides, so a commit that names another producer cannot move pins.

name_machine other-host
json_edit "$up_inst/versions.lock.json" '.agent_tools.codex.linux.version = "2.0.0"'
json_edit "$up_inst/flake.lock" '.nodes.nixpkgs.locked.rev = "9999999"'
allowed "chore: move codex and nixpkgs on the producer"

name_machine example-host
sed -i '/^producer = /d' "$up_inst/workstation.toml"
allowed "chore(hosts): no producer"
json_edit "$up_inst/versions.lock.json" '.agent_tools.codex.linux.version = "3.0.0"'
allowed "chore: move codex without a producer"
