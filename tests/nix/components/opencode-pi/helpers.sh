# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Helpers for the opencode-pi component tests. Not a test file.
#
# Builds on tests/nix/instance/helpers.sh (and through it
# tests/nix/core/helpers.sh: isolated Nix store, locked nixpkgs and
# home-manager). Two kinds of evaluation:
#
#   op_json EXPR            the JSON value of EXPR with scope.nix in scope
#                           (the core prelude plus the component: seed, cfg,
#                           home, component, piFor, ...); the test fails when
#                           the evaluation fails
#   op_raw EXPR             the string value of EXPR
#   assert_op_eq JSON EXPR [MESSAGE]
#                           EXPR evaluates to JSON (normalized with jq -S)
#   assert_op_fails EXPR NEEDLE...
#                           the evaluation fails with every NEEDLE on stderr
#
# and real instances evaluated by lib.mkInstance with the real catalog
# (tests/nix/instance/prelude.nix), driven through the framework CLI:
#
#   op_instance NAME [TOML_LINES]
#                           writes the instance DS_TEST_ROOT/NAME and prints
#                           its path: nix.systems ["x86_64-linux"], the
#                           profile "workstation" (fresh mode),
#                           [components.opencode-pi] enable = true and
#                           method = "external" followed by TOML_LINES; the
#                           minimal instance lock with the seed's
#                           versions_lock merged in (what dotsteward init
#                           writes); the vendored skills alpha-skill and
#                           beta-skill and their skills lock, whose nix_tools
#                           mirrors the seed's Pi version; home.nix without
#                           framework skills (no built generation needed);
#                           and its .dotsteward/ mirrors
#   op_cli DIR ARG...       the framework CLI of the checkout under test with
#                           --instance DIR (standard input empty)
#   op_hermetic_path        drops every PATH directory that holds an
#                           opencode, pi or local-maintained-files command of
#                           the host, then puts DS_TEST_ROOT/tools first: a
#                           stand-in for the local-maintained-files alias
#                           core requires

# shellcheck source=tests/nix/instance/helpers.sh
source "$DS_REPO_ROOT/tests/nix/instance/helpers.sh"

# The isolated store and the nixpkgs and home-manager paths, once per test
# file (evaluations run in command substitutions, whose setup would be lost).
nix_core_init

op_dir=$DS_REPO_ROOT/modules/components/opencode-pi
# shellcheck disable=SC2034 # read by the test files
op_seed=$op_dir/seed.json
_op_minimal=$DS_REPO_ROOT/tests/fixtures/instances/minimal

# _op_expr EXPR: EXPR with scope.nix in scope; nixpkgs, homeManager and repo
# are the arguments of the expression nix_core_eval builds.
_op_expr() {
  printf 'with import (/. + repo + "/tests/nix/components/opencode-pi/scope.nix") { inherit nixpkgs homeManager repo; }; (%s)' "$1"
}

op_json() {
  core_json "$(_op_expr "$1")"
}

op_raw() {
  op_json "$1" | jq -j .
}

assert_op_eq() {
  (($# >= 2)) || ds_fail "assert_op_eq: usage: assert_op_eq EXPECTED_JSON EXPR [MESSAGE]"
  local expected actual
  expected=$(jq -S . <<<"$1") || ds_fail "assert_op_eq: invalid expected JSON: $1"
  actual=$(op_json "$2" | jq -S .)
  assert_eq "$expected" "$actual" "${3:-$2}"
}

assert_op_fails() {
  (($# >= 2)) || ds_fail "assert_op_fails: usage: assert_op_fails EXPR NEEDLE..."
  local expr=$1
  shift
  assert_core_fails "$(_op_expr "$expr")" "$@"
}

# _op_skill DIR NAME: a vendored skill NAME in DIR/agent/skills/NAME; prints
# its skills lock entry.
_op_skill() {
  local skill=$1/agent/skills/$2
  mkdir -p "$skill"
  printf -- '---\nname: %s\ndescription: Synthetic skill %s.\n---\n\nSynthetic.\n' "$2" "$2" >"$skill/SKILL.md"
  jq -cn --arg name "$2" --arg sha "$(sha256sum "$skill/SKILL.md" | cut -d ' ' -f 1)" \
    '{ name: $name, directory: $name, skill_sha256: $sha }'
}

op_instance() {
  (($# >= 1 && $# <= 2)) || ds_fail "op_instance: usage: op_instance NAME [TOML_LINES]"
  local dir=$DS_TEST_ROOT/$1 extra=${2:-} entries pi_version
  [[ -f $op_seed ]] || ds_fail "missing $op_seed"
  rm -rf -- "$dir"
  mkdir -p "$dir/agent/skills"
  cp -R "$_op_minimal/home" "$_op_minimal/local-maintained-files" "$dir/"
  chmod -R u+w "$dir"
  cat >"$dir/workstation.toml" <<EOF
schema_version = 1

[identity]
username = "alice"

[instance]
remote = "git@github.com:alice/workstation.git"

[nix]
systems = ["x86_64-linux"]
state_version = "25.11"

[profiles]
names = ["workstation"]

[components.opencode-pi]
enable = true
method = "external"
$extra
EOF
  jq --indent 2 -s '.[0] * .[1].versions_lock' "$_op_minimal/versions.lock.json" "$op_seed" \
    >"$dir/versions.lock.json"
  entries=$({ _op_skill "$dir" alpha-skill && _op_skill "$dir" beta-skill; } | jq -cs .)
  pi_version=$(jq -r '.versions_lock.agent_tools.pi.version' "$op_seed")
  jq -n --argjson skills "$entries" --arg pi "$pi_version" \
    '{ schema_version: "1.0", expected_skill_count: ($skills | length), skills: $skills,
       nix_tools: { pi: $pi } }' >"$dir/agent/skills.lock.json"
  printf '{ ... }:\n{\n  dotsteward.skills.framework = [ ];\n}\n' >"$dir/home.nix"
  write_mirrors "instance { root = /. + \"$dir\"; }" "$dir"
  printf '%s\n' "$dir"
}

op_cli() {
  (($# >= 2)) || ds_fail "op_cli: usage: op_cli DIR ARG..."
  local dir=$1
  shift
  "$DS_REPO_ROOT/cli/dotsteward" --instance "$dir" "$@" </dev/null
}

op_hermetic_path() {
  local entry kept=() tools=$DS_TEST_ROOT/tools
  local IFS=:
  for entry in $PATH; do
    [[ -n $entry && ! -e $entry/opencode && ! -e $entry/pi && ! -e $entry/local-maintained-files ]] || continue
    kept+=("$entry")
  done
  mkdir -p "$tools"
  printf '#!%s\nexit 0\n' "$BASH" >"$tools/local-maintained-files"
  chmod 0755 "$tools/local-maintained-files"
  PATH="$tools:${kept[*]}"
  export PATH
  hash -r
}
