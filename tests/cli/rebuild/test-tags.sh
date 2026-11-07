# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# E19: rebuild hands the effective tags to Nix: in profile.nix only when there are any, and a
# host flake that passes mkHome only what it takes, so an older framework pin keeps working.
# The generation of the gate is reused only for the same tags.
# shellcheck source=tests/cli/rebuild/helpers.sh
source "$DS_REPO_ROOT/tests/cli/rebuild/helpers.sh"

record=$rb_state/update/generation.json
gate_generation=$(make_generation gate-generation)

# Without a name: no key at all.
assert_exit 0 run_rebuild --profile workstation --build-only
assert_not_contains "$(<"$rb_hosts/profile.nix")" 'tags'
assert_contains "$(<"$rb_hosts/flake.nix")" 'builtins.intersectAttrs (builtins.functionArgs dotfiles.lib.mkHome) (import ./profile.nix)'

# A machine with tags, a declined component and a component for it.
mkdir -p "$rb_inst/hosts"
cat >"$rb_inst/hosts/laptop.toml" <<'TOML'
schema_version = 1
system = "x86_64-linux"
profile = "workstation"
tags = ["small", "nvidia"]
declined = { components = ["example-app"] }
TOML
instance_commit "chore: a host"
jq -n '{schema_version: 1, name: "laptop", machine_key: "00", named_at: "2026-01-01T00:00:00Z",
  host: {system: "x86_64-linux", profile: "workstation", platform: "ubuntu-24.04", tags: []}}' >"$rb_state/machine.json"
assert_exit 0 run_rebuild --profile workstation --build-only
assert_contains "$(<"$rb_hosts/profile.nix")" 'tags = [ "machine:laptop" "no:example-app" "nvidia" "small" ];'

# The gate built for these tags: reused. For others: built.
tags_sha256() {
  printf '%s\n%s\n%s\n%s' 'machine:laptop' 'no:example-app' nvidia small | sha256sum | cut -d' ' -f1
}
handoff() {
  jq -n --arg tree "$(git -C "$rb_inst" rev-parse 'HEAD^{tree}')" --arg user "$USER" --arg home "$HOME" \
    --arg generation "$gate_generation" --arg root "$rb_inst" --arg tags "$1" '{
      schema_version: "1.0", tree_oid: $tree, profile: "workstation", system: "x86_64-linux",
      username: $user, home: $home, generation: $generation, framework_override: null,
      root: $root, recorded_at: "2026-01-01T00:00:00Z", host: "laptop", tags_sha256: $tags}' >"$record"
  chmod 0600 "$record"
}
mkdir -p "$rb_state/update"
chmod 0700 "$rb_state/update"
handoff "$(tags_sha256)"
: >"$DS_CALL_LOG"
assert_exit 0 run_rebuild --profile workstation --build-only
assert_contains "$DS_STDOUT$DS_STDERR" "$gate_generation"
assert_not_contains "$(<"$DS_CALL_LOG")" 'nix --extra-experimental-features nix-command flakes build'

handoff "$(printf 'other' | sha256sum | cut -d' ' -f1)"
: >"$DS_CALL_LOG"
assert_exit 0 run_rebuild --profile workstation --build-only
assert_contains "$(<"$DS_CALL_LOG")" ' build '

# A record of the gate of an older release says nothing about tags: it fits no tags at all.
handoff "$(tags_sha256)"
jq 'del(.tags_sha256, .host)' "$record" >"$record.new"
mv -- "$record.new" "$record"
chmod 0600 "$record"
: >"$DS_CALL_LOG"
assert_exit 0 run_rebuild --profile workstation --build-only
assert_contains "$(<"$DS_CALL_LOG")" ' build '
rm -f -- "$rb_state/machine.json" "$rb_inst/hosts/laptop.toml"
instance_commit "chore: no host"
handoff "$(tags_sha256)"
jq 'del(.tags_sha256, .host)' "$record" >"$record.new"
mv -- "$record.new" "$record"
chmod 0600 "$record"
: >"$DS_CALL_LOG"
assert_exit 0 run_rebuild --profile workstation --build-only
assert_not_contains "$(<"$DS_CALL_LOG")" ' build '

# The activation record says which tags the machine runs with.
write_tagged() {
  mkdir -p "$rb_inst/hosts"
  printf 'schema_version = 1\nsystem = "x86_64-linux"\nprofile = "workstation"\ntags = ["nvidia"]\n' >"$rb_inst/hosts/laptop.toml"
  instance_commit "chore: a host again"
  jq -n '{schema_version: 1, name: "laptop", machine_key: "00", named_at: "2026-01-01T00:00:00Z",
    host: {system: "x86_64-linux", profile: "workstation", platform: "ubuntu-24.04", tags: []}}' >"$rb_state/machine.json"
}
write_tagged
assert_exit 0 run_rebuild --profile workstation --switch
assert_json "$rb_current/activation.json" '.tags == ["machine:laptop", "nvidia"]'
