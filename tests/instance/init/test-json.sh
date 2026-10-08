# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs and literal texts are single-quoted on purpose
# init --json: standard output is exactly one JSON
# document (the directory, remote, components, systems, profiles, framework
# URL, commit and next steps); the output of the steps goes to standard
# error. A refusal prints nothing on standard output.
# shellcheck source=tests/instance/init/helpers.sh
source "$DS_REPO_ROOT/tests/instance/init/helpers.sh"

init_use_nix
mkdir -p "$DS_TEST_ROOT/instances"
dir=$DS_TEST_ROOT/instances/station

init_run 0 --dir "$dir" --remote "$init_remote" --components herdr,shell --profiles dev,new --json
assert_eq 1 "$(jq -s length <<<"$DS_STDOUT")" "one JSON document"
document=$DS_STDOUT
template_url=$(sed -n 's/^ *url = "\(github:[^"]*dotsteward[^"]*\)";$/\1/p' "$tpl/flake.nix")
assert_jq - '. == {
  schema_version: 1,
  dir: $dir,
  remote: "git@github.com:alice/workstation.git",
  components: ["shell", "herdr"],
  systems: ["x86_64-linux"],
  profiles: { names: ["dev", "new"], check: "dev", bootstrap: "new" },
  framework_url: $url,
  commit: $commit,
  next_steps: .next_steps
}' --arg dir "$dir" --arg url "$template_url" --arg commit "$(git -C "$dir" rev-parse HEAD)" <<<"$document"
assert_jq - '.next_steps | length == 5 and all(.[]; (keys == ["command", "description"]) and (.command | length > 0))' \
  <<<"$document"
# The order of the instance's AGENTS.md: the gate proves the tree before the
# first push.
assert_jq - '.next_steps[0].command == "git -C \($dir) remote add origin git@github.com:alice/workstation.git"' \
  --arg dir "$dir" <<<"$document"
assert_jq - '.next_steps[1].command == "cd \($dir) && ./.dotsteward/cli.sh gate --scope maintain"' \
  --arg dir "$dir" <<<"$document"
assert_jq - '.next_steps[2].command == "git -C \($dir) push -u origin main"' --arg dir "$dir" <<<"$document"
assert_jq - '.next_steps[3].command == "cd \($dir) && ./bootstrap.sh --profile new"' --arg dir "$dir" <<<"$document"
assert_jq - '.next_steps[4].command == "cd \($dir) && ./rebuild.sh --profile dev --switch && ./.dotsteward/cli.sh e2e --profile dev"' \
  --arg dir "$dir" <<<"$document"
# The progress and the steps' output went to standard error.
assert_contains "$DS_STDERR" "[dotsteward] Wrote mirror .dotsteward/manifest.x86_64-linux.json"
assert_contains "$DS_STDERR" "[pins]"
assert_not_contains "$DS_STDOUT" "[dotsteward]"

# --no-git: no commit, and the first next step makes it.
rm -rf "$dir"
init_run 0 --dir "$dir" --remote "$init_remote" --no-git --json
assert_jq - '.commit == null' <<<"$DS_STDOUT"
assert_jq - '.next_steps[0] == { description: "Commit the instance", command: "git -C \($dir) init -b main && git -C \($dir) add -A && git -C \($dir) commit -m '"'"'chore: initialize dotsteward instance'"'"'" }' \
  --arg dir "$dir" <<<"$DS_STDOUT"
[[ ! -e $dir/.git ]] || ds_fail "--no-git initialized a repository"

# A refusal prints nothing on standard output.
init_run 1 --dir "$dir" --remote "$init_remote" --json
assert_eq "" "$DS_STDOUT" "no document for a refusal"
assert_contains "$DS_STDERR" "is not empty and is not a dotsteward template"
init_run 2 --dir "$dir" --json
assert_eq "" "$DS_STDOUT" "no document for a usage error"
