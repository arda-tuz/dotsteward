# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs and literal texts are single-quoted on purpose
# What init writes is privacy clean. An instance with
# every catalog component on both systems passes the privacy scan of its
# tree and the instance static privacy check, holds no trace of the
# temporary directory it was composed in, and its commit carries only the
# user's identity, with no trailer.
# shellcheck source=tests/instance/init/helpers.sh
source "$DS_REPO_ROOT/tests/instance/init/helpers.sh"

init_use_nix

dir=$HOME/workstation
init_run 0 --dir "$dir" --remote "$init_remote" --components "$(
  IFS=,
  echo "${init_catalog[*]}"
)" --systems x86_64-linux,aarch64-darwin \
  --method-platform vscode=linux:deb,darwin:app-archive --allow-unfree
stage=$(<"$DS_STUB_STATE/nix/staged/1.root")

(
  cd "$dir"
  assert_exit 0 "$DS_CLI" scan --tree
  assert_contains "$DS_STDOUT" "scan clean"
  assert_exit 0 "$DS_CLI" --instance "$dir" static --sandbox --only privacy
)
instance_contract "$dir" x86_64-linux
instance_contract "$dir" aarch64-darwin

# No file names the staging directory, TMPDIR or the framework checkout.
for needle in "$stage" "$(cd "$TMPDIR" && pwd -P)" "$DS_REPO_ROOT" dotsteward-init.; do
  hits=$(grep -rlF --exclude-dir=.git -- "$needle" "$dir" || true)
  assert_eq "" "$hits" "files naming $needle"
done

# The commit: the user's identity only, the subject alone.
assert_eq "chore: initialize dotsteward instance" "$(git -C "$dir" log -1 --format=%B | sed '/^$/d')" "commit message"
assert_eq "" "$(git -C "$dir" log -1 --format='%(trailers)')" "no trailer"
