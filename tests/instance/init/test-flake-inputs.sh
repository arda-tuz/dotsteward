# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs and literal texts are single-quoted on purpose
# Init writes the chosen components' flake inputs
# between the "# dotsteward:inputs:begin" and "# dotsteward:inputs:end" lines
# of flake.nix (url, flake = false and follows, one line each, in catalog
# order, an input shared by two seeds once), replacing what was there, and
# changes nothing else but the dotsteward input's reference for
# --framework-ref or --framework-url. A flake.nix without exactly one pair
# of markers in order is refused.
# shellcheck source=tests/instance/init/helpers.sh
source "$DS_REPO_ROOT/tests/instance/init/helpers.sh"

init_use_nix
mkdir -p "$DS_TEST_ROOT/instances"
station=$DS_TEST_ROOT/instances/station

# composed CLI ARG...: runs init of station with ARG, stopped after the
# lock, and prints the staged copy.
composed() {
  local cli=$1
  shift
  assert_exit 1 env DS_INIT_NIX_FAIL='eval *' "$cli" init --dir "$station" --remote "$init_remote" "$@"
  assert_contains "$DS_STDERR" "dotsteward sync --nix failed"
  init_staged
}

# flake_inputs FILE: the inputs of the flake.nix FILE as JSON (imported by
# Nix, so the file must parse).
flake_inputs() {
  inst_json "(import (/. + \"$1\")).inputs"
}

# without_block FILE: FILE without the lines between the markers.
without_block() {
  sed '/# dotsteward:inputs:begin/,/# dotsteward:inputs:end/{/# dotsteward:inputs:/!d}' "$1"
}

template_inputs=$(flake_inputs "$tpl/flake.nix")
template_url=$(jq -r .dotsteward.url <<<"$template_inputs")

# --- the herdr seed ---------------------------------------------------------------------

staged=$(composed "$DS_CLI" --components shell,herdr)
seed=$DS_REPO_ROOT/modules/components/herdr/seed.json
assert_eq "    herdr.url = \"$(jq -r .flake_inputs.herdr.url "$seed")\";" "$(flake_inputs_block "$staged/flake.nix")" \
  "the herdr input between the markers"
assert_eq "$(without_block "$tpl/flake.nix")" "$(without_block "$staged/flake.nix")" "nothing else changed"
assert_eq "$(jq -c --slurpfile seed "$seed" '. + $seed[0].flake_inputs' <<<"$template_inputs" | jq -S .)" \
  "$(flake_inputs "$staged/flake.nix" | jq -S .)" "the inputs Nix reads"

# No component with inputs: an empty block.
staged=$(composed "$DS_CLI" --components shell,codex)
assert_eq "" "$(flake_inputs_block "$staged/flake.nix")" "no input"
cmp -s "$tpl/flake.nix" "$staged/flake.nix" || ds_fail "flake.nix changed without inputs"

# --- the framework reference ---------------------------------------------------------------

[[ $template_url =~ ^github:[^/]+/[^/]+/v[0-9]+\.[0-9]+\.[0-9]+$ ]] || ds_fail "unexpected template url $template_url"
staged=$(composed "$DS_CLI" --framework-ref v1.2.3)
assert_eq "${template_url%/*}/v1.2.3" "$(flake_inputs "$staged/flake.nix" | jq -r .dotsteward.url)" "--framework-ref"
assert_eq "$(jq -S 'del(.dotsteward.url)' <<<"$template_inputs")" \
  "$(flake_inputs "$staged/flake.nix" | jq -S 'del(.dotsteward.url)')" "the follows stay"
staged=$(composed "$DS_CLI" --framework-url "git+file://$DS_REPO_ROOT?ref=main")
assert_eq "git+file://$DS_REPO_ROOT?ref=main" "$(flake_inputs "$staged/flake.nix" | jq -r .dotsteward.url)" \
  "--framework-url"
assert_eq "$(diff <(without_block "$tpl/flake.nix") <(without_block "$staged/flake.nix") | grep -c '^[<>]')" 2 \
  "only the url line changed"

# A full run with a path: framework, as CI runs init: the lock records it.
init_run 0 --dir "$DS_TEST_ROOT/instances/ci" --remote "$init_remote" --components herdr \
  --framework-url "path:$DS_REPO_ROOT"
assert_jq "$DS_TEST_ROOT/instances/ci/flake.lock" '.nodes.dotsteward.locked == { type: "path", path: $repo, narHash: .nodes.dotsteward.locked.narHash }' \
  --arg repo "$DS_REPO_ROOT"
assert_jq "$DS_TEST_ROOT/instances/ci/flake.lock" '.nodes.herdr.locked.rev == $seed[0].versions_lock.flake_inputs.herdr.revision' \
  --slurpfile seed "$seed"
assert_eq "    herdr.url = \"$(jq -r .flake_inputs.herdr.url "$seed")\";" \
  "$(flake_inputs_block "$DS_TEST_ROOT/instances/ci/flake.nix")" "the committed flake.nix"

# --- rendering: flake = false, follows, a shared input (synthetic seeds) -----------------

fw=$(framework_copy)
jq '.flake_inputs.herdr += { flake: false } | .flake_inputs.extra = { url: "github:example/extra/v1.0.0", inputs: { nixpkgs: { follows: "nixpkgs" } } }
  | .versions_lock.flake_inputs.extra = { reference: "github:example/extra/v1.0.0", revision: "1111111111111111111111111111111111111111" }' \
  "$seed" >"$fw/modules/components/herdr/seed.json"
jq '.flake_inputs = { extra: { url: "github:example/extra/v1.0.0", inputs: { nixpkgs: { follows: "nixpkgs" } } } }
  | .versions_lock.flake_inputs = { extra: { reference: "github:example/extra/v1.0.0", revision: "1111111111111111111111111111111111111111" } }' \
  "$DS_REPO_ROOT/modules/components/codex/seed.json" >"$fw/modules/components/codex/seed.json"
staged=$(composed "$fw/cli/dotsteward" --components codex,herdr)
assert_eq "    herdr.url = \"$(jq -r .flake_inputs.herdr.url "$seed")\";
    herdr.flake = false;
    extra.url = \"github:example/extra/v1.0.0\";
    extra.inputs.nixpkgs.follows = \"nixpkgs\";" "$(flake_inputs_block "$staged/flake.nix")" "rendered inputs"
assert_jq - '.herdr.flake == false and .extra.inputs.nixpkgs.follows == "nixpkgs"' <<<"$(flake_inputs "$staged/flake.nix")"

# The same input declared differently by two seeds is refused.
jq '.flake_inputs.extra.url = "github:example/extra/v2.0.0"' "$fw/modules/components/codex/seed.json" >"$fw/codex.json"
mv "$fw/codex.json" "$fw/modules/components/codex/seed.json"
: >"$DS_CALL_LOG"
assert_exit 1 "$fw/cli/dotsteward" init --dir "$station" --remote "$init_remote" --components codex,herdr
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the seeds of herdr and codex declare the flake input extra differently"
assert_call_count 0 nix

# --- the markers of a template directory ------------------------------------------------------

# template_dir FLAKE_EDIT: a template directory (as `nix flake init -t`
# leaves it) whose flake.nix the sed script FLAKE_EDIT changed.
template_dir() {
  rm -rf "$station"
  mkdir -p "$station"
  cp -R "$tpl/." "$station/"
  chmod -R u+w "$station"
  sed -i "$1" "$station/flake.nix"
}

# Something between the markers already: replaced.
template_dir 's|# dotsteward:inputs:begin|&\n    stale.url = "github:example/stale/v0.1.0";|'
staged=$(composed "$DS_CLI" --components herdr)
assert_eq "    herdr.url = \"$(jq -r .flake_inputs.herdr.url "$seed")\";" "$(flake_inputs_block "$staged/flake.nix")" \
  "the block is replaced"
grep -q 'stale' "$station/flake.nix" || ds_fail "a failed init changed the template directory"

for edit in '/# dotsteward:inputs:begin/d' '/# dotsteward:inputs:end/d' \
  's|# dotsteward:inputs:end|&\n    # dotsteward:inputs:end|' \
  '/# dotsteward:inputs:begin/d;s|\(.*\)# dotsteward:inputs:end|&\n\1# dotsteward:inputs:begin|'; do
  template_dir "$edit"
  before=$(tree_state "$station")
  : >"$DS_CALL_LOG"
  init_run 1 --dir "$station" --remote "$init_remote" --components herdr
  assert_contains "$DS_STDERR" "flake.nix"
  assert_contains "$DS_STDERR" "dotsteward:inputs:"
  assert_call_count 0 nix
  assert_unchanged "$station" "$before" "a refused init changed the template directory"
done
