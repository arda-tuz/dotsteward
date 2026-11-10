# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The read only `files` action of the apt engine says what `policy` writes: after policy the
# texts are the bytes of the files, before it the paths where they go, and with
# `[apt.gated] enable = false` no pin text; the dpkg hook of policy keeps the pin file at that text.
# `dotsteward e2e` (core:apt-files) holds the files to it.
# shellcheck source=tests/apt-worlds/helpers.sh
source "$DS_REPO_ROOT/tests/apt-worlds/helpers.sh"
world_require

files() {
  FILES=$DS_TEST_ROOT/out/files.json
  mkdir -p "${FILES%/*}"
  APT_CONFIG=$WORLD/apt.conf ds_python dotsteward_cli.apt_plan files --request - <<<"${1:-{\}}" >"$FILES" 2>"$FILES.err" ||
    ds_fail "files failed: $(<"$FILES.err")"
}
policy() {
  APT_CONFIG=$WORLD/apt.conf DOTSTEWARD_APT_SUDO='' ds_python dotsteward_cli.apt_plan policy --request - \
    <<<"${1:-{\}}" >/dev/null 2>"$DS_TEST_ROOT/policy.err" || ds_fail "policy failed: $(<"$DS_TEST_ROOT/policy.err")"
}

world_up driver-respin
real=$WORLD/etc/apt/preferences.d/60dotsteward
unattended=$WORLD/etc/apt/apt.conf.d/52dotsteward-unattended-upgrades
before=$(find "$WORLD/etc" -printf '%p %s\n' | LC_ALL=C sort)
files
assert_eq "$before" "$(find "$WORLD/etc" -printf '%p %s\n' | LC_ALL=C sort)" "files writes nothing"
assert_json "$FILES" ".pin.path == \"$real\" and .unattended.path == \"$unattended\""
assert_json "$FILES" '.pin.text | contains("src:linux-meta*:any")'
policy
files
assert_eq "$(<"$real")" "$(jq -r .pin.text "$FILES")" "the pin text is the file"
assert_eq "$(<"$unattended")" "$(jq -r .unattended.text "$FILES")" "the unattended text is the file"
cmp -s "$real" <(jq -j .pin.text "$FILES") || ds_fail "the pin text is not the bytes of the file"

# After every dpkg run the hook of policy rewrites the pin file from what dpkg has: what it writes
# is still the text of `files`, so the check of E2E stays green after the first terminal run.
hook=$(sed -n 's/^post-invoke="\(.*\)"$/\1/p' "$WORLD/etc/dpkg/dpkg.cfg.d/60dotsteward-pin")
[[ -n $hook ]] || ds_fail "policy wrote no dpkg hook"
hook=${hook% >/dev/null 2>&1 || true}
eval "$hook" || ds_fail "the dpkg hook failed"
files
cmp -s "$real" <(jq -j .pin.text "$FILES") || ds_fail "the pin file after the dpkg hook is not the text of files"

files '{"gated": false}'
assert_json "$FILES" '.pin.text == null'
