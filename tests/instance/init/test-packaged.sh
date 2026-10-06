# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs and literal texts are single-quoted on purpose
# init from the packaged CLI (packages.<system>.dotsteward), as
# `nix run <framework>#dotsteward -- init ...` runs it: the package ships
# the template and the component seeds, its python has tomlkit, and an
# instance made from the read-only store copy of the template is writable,
# holds the package's template files byte for byte and passes the instance
# contract of that CLI.
#
# Input: DS_INIT_PACKAGED_CLI, the packaged dotsteward command (checks.init
# sets it). Without it the package of the checkout under test is built with
# the host Nix.
# shellcheck source=tests/instance/init/helpers.sh
source "$DS_REPO_ROOT/tests/instance/init/helpers.sh"

if [[ -n ${DS_INIT_PACKAGED_CLI:-} ]]; then
  cli=$DS_INIT_PACKAGED_CLI
else
  command -v nix >/dev/null 2>&1 || ds_fail "the packaged init test needs DS_INIT_PACKAGED_CLI or nix"
  case $(uname -m) in
    x86_64 | amd64) machine=x86_64 ;;
    arm64 | aarch64) machine=aarch64 ;;
    *) ds_fail "unsupported machine: $(uname -m)" ;;
  esac
  case $(uname -s) in
    Linux) system=$machine-linux ;;
    Darwin) system=$machine-darwin ;;
    *) ds_fail "unsupported system: $(uname -s)" ;;
  esac
  out=$(nix --extra-experimental-features 'nix-command flakes' build --no-link --print-out-paths \
    "$DS_REPO_ROOT#packages.$system.dotsteward") || ds_fail "cannot build the dotsteward package with Nix"
  cli=$out/bin/dotsteward
fi
[[ -x $cli ]] || ds_fail "not an executable: $cli"
share=$(cd "$(dirname "$(readlink -f "$cli")")/.." && pwd -P)/share/dotsteward
[[ -f $share/template/workstation.toml ]] || ds_fail "the package has no template: $share"
for name in "${init_catalog[@]}"; do
  [[ -f $share/modules/components/$name/seed.json ]] || ds_fail "the package has no seed of $name"
done

init_use_nix
# Every CLI call of this test, the contract steps included, is the package's.
DS_CLI=$cli

dir=$HOME/workstation
init_run 0 --dir "$dir" --remote "$init_remote" --components shell,herdr,opencode-pi
assert_contains "$DS_STDOUT" "[dotsteward] Initialized the dotsteward instance in $dir"

# The package's template, byte for byte, in writable files.
while IFS= read -r -d '' file; do
  file=${file#./}
  case $file in workstation.toml | versions.lock.json | agent/skills.lock.json | flake.nix) continue ;; esac
  cmp -s "$share/template/$file" "$dir/$file" || ds_fail "$file differs from the package's template"
  file_mode=$(stat -c %a "$dir/$file")
  [[ $file_mode == 644 || $file_mode == 755 ]] || ds_fail "$file has mode $file_mode"
done < <(cd "$share/template" && find . -type f -print0)
assert_eq "" "$(find "$dir" -path "$dir/.git" -prune -o ! -perm -u+w -print)" "every file is writable"
assert_eq "" "$(git -C "$dir" status --porcelain --untracked-files=all)" "clean tree"
assert_jq "$dir/agent/skills.lock.json" '.nix_tools.pi | type == "string"'
instance_contract "$dir" x86_64-linux

# The package's catalog is the framework's.
assert_exit 2 "$cli" init --dir "$DS_TEST_ROOT/other" --remote "$init_remote" --components editor
assert_contains "$DS_STDERR" "unknown component: editor (the catalog: shell, herdr, claude-code, codex, opencode-pi, vscode)"
