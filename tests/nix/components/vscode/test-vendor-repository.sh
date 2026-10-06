# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables come from the harness; errexit stops a failed cd
# The framework never blocks VS Code's own update channel (SPEC 3.5, policy
# native_application_updates): the code package's installer offers to add
# the vendor's apt repository, which keeps VS Code current after the
# pinned DEB, and nothing in the framework's production sources (everything
# but tests/) answers that question with false, removes or rewrites the
# repository's apt source, or pins its origin away. Downgrades are refused
# by the framework's bans check. A planted copy of each kind of block is
# found.
# shellcheck source=tests/nix/components/vscode/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/vscode/helpers.sh"

# vendor_blocks ROOT: "path:line: reason" for every production line of the
# framework source ROOT that blocks the vendor repository.
vendor_blocks() {
  local root=$1
  (
    cd "$root"
    local -a sources=()
    local path
    while IFS= read -r -d '' path; do
      sources+=("${path#./}")
    done < <(find . \( -path ./tests -o -path ./.git \) -prune -o -type f ! -name '*.pyc' -print0 | LC_ALL=C sort -z)
    ((${#sources[@]})) || exit 0
    grep -HniE 'add-microsoft-repo.*(false|no)\b' -- "${sources[@]}" | sed -E 's/^([^:]+:[0-9]+):.*/\1: the repository question answered no/' || true
    grep -HnE 'sources\.list\.d/vscode' -- "${sources[@]}" | sed -E 's/^([^:]+:[0-9]+):.*/\1: the repository apt source touched/' || true
    grep -HnE 'packages\.microsoft\.com' -- "${sources[@]}" | sed -E 's/^([^:]+:[0-9]+):.*/\1: the repository origin named/' || true
  )
}

# The real tree, including the component's README.
assert_eq "" "$(vendor_blocks "$DS_REPO_ROOT")" "production sources blocking the vendor repository"
[[ -f $vscode_component/default.nix ]] || ds_fail "missing modules/components/vscode/default.nix"

# Downgrades: the framework's bans check passes on the real tree.
cd "$DS_REPO_ROOT"
assert_exit 0 "$DS_REPO_ROOT/cli/dotsteward" static --sandbox --only bans

# Each kind of block is found in a production file, never in tests/.
fw=$DS_TEST_ROOT/fw
mkdir -p "$fw/cli/lib" "$fw/modules/components/vscode" "$fw/tests/extra"
printf 'printf "%%s\\n" "code code/add-microsoft-repo boolean false" | sudo debconf-set-selections\n' >"$fw/cli/lib/a.sh"
printf 'sudo rm -f /etc/apt/sources.list.d/vscode.sources\n' >"$fw/cli/lib/b.sh"
printf '{ ... }: { text = "Package: code\\nPin: origin packages.microsoft.com\\nPin-Priority: -1\\n"; }\n' \
  >"$fw/modules/components/vscode/c.nix"
cp "$fw/cli/lib/a.sh" "$fw/tests/extra/a.sh"
assert_eq "cli/lib/a.sh:1: the repository question answered no
cli/lib/b.sh:1: the repository apt source touched
modules/components/vscode/c.nix:1: the repository origin named" "$(vendor_blocks "$fw" | LC_ALL=C sort)" "planted blocks"
