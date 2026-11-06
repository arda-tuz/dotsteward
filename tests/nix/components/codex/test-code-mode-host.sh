# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Codex needs a second release asset: from 0.144.0 on it runs Code Mode, and
# with it apply_patch, through codex-code-mode-host, a file it looks for next
# to its own resolved executable. The fixture release below does the same:
# `codex session` starts the helper from that path, or fails with the words
# of the real binary.
#
# The official-binary method installs the helper from its own pin, next to
# codex, and the E2E hook codex-code-mode-host goes red when a codex that
# needs it cannot start it:
#   - a fresh install fetches both archives, and a real session resolves;
#   - a missing helper is red; install fetches only the helper;
#   - a helper already in place is kept without a download, with or without
#     a pin, so a machine that placed it by hand stays green;
#   - a pin bump replaces both files together, never one of them;
#   - a helper archive that differs from its pin is refused before anything
#     is replaced;
#   - a pin older than the first version that needs the helper asks nothing;
#   - a codex installed as a link by its standalone installer has its helper
#     next to the link's target and is not touched;
#   - the pins engine ties the helper pin to the codex pin.
# shellcheck source=tests/nix/components/codex/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/codex/helpers.sh"

codex_hermetic_path
ds_use_stubs curl

component=$DS_REPO_ROOT/modules/components/codex
dest=$HOME/.local/bin/codex
helper=$HOME/.local/bin/codex-code-mode-host
target=x86_64-unknown-linux-musl
codex_pin=agent_tools.codex.linux
host_pin=agent_tools.codex-code-mode-host.linux
base=https://github.com/openai/codex/releases/download/rust-v

# codex_url VERSION, host_url VERSION: the release URLs of the two archives.
codex_url() { printf '%s%s/codex-%s.tar.gz' "$base" "$1" "$target"; }
host_url() { printf '%s%s/codex-code-mode-host-%s.tar.gz' "$base" "$1" "$target"; }

# write_codex VERSION FILE: a codex that prints VERSION and, for `session`,
# starts the helper the way the real binary does: from the directory of its
# resolved executable.
write_codex() {
  {
    printf '#!%s\n' "$BASH"
    printf 'if [[ ${1:-} == --version ]]; then printf "codex-cli %%s\\n" %q; exit 0; fi\n' "$1"
    # shellcheck disable=SC2016 # lines of the fixture
    printf '%s\n' \
      'host=$(dirname -- "$(readlink -f -- "$0")")/codex-code-mode-host' \
      '[[ -x $host ]] || { printf "failed to spawn code-mode host %s: No such file or directory\n" "$host" >&2; exit 1; }' \
      'exec "$host" --session'
  } >"$2"
  chmod 0755 "$2"
}

# write_host TAG FILE: a helper that prints TAG; `--help` succeeds, as it does
# for the real helper, which has no --version.
write_host() {
  {
    printf '#!%s\n' "$BASH"
    printf 'printf "code-mode-host %%s\\n" %q\n' "$1"
  } >"$2"
  chmod 0755 "$2"
}

# archive KIND TAG OUT: the archive of a release: one member, named after the
# asset without .tar.gz.
archive() {
  local dir member
  dir=$(mktemp -d "$DS_TEST_ROOT/release.XXXXXX")
  case $1 in
    codex)
      member=codex-$target
      write_codex "$2" "$dir/$member"
      ;;
    host)
      member=codex-code-mode-host-$target
      write_host "$2" "$dir/$member"
      ;;
  esac
  tar -czf "$3" -C "$dir" "$member"
  rm -rf -- "$dir"
}

# pin_of VERSION URL FILE: a lock entry that describes FILE.
pin_of() {
  jq -n --arg v "$1" --arg u "$2" --argjson s "$(stat -c %s -- "$3")" \
    --arg h "$(sha256sum -- "$3" | awk '{print $1}')" \
    '{ version: $v, url: $u, size: $s, sha256: $h }'
}

# publish_codex DIR VERSION, publish_host DIR VERSION: serve the archive of
# VERSION and pin the instance in DIR to it.
publish_codex() {
  local file=$DS_TEST_ROOT/codex-$2.tar.gz
  archive codex "$2" "$file"
  ds_curl_serve "$(codex_url "$2")" "$file"
  codex_lock_set "$1" "$codex_pin" "$(pin_of "$2" "$(codex_url "$2")" "$file")"
}
publish_host() {
  local file=$DS_TEST_ROOT/host-$2.tar.gz
  archive host "$2" "$file"
  ds_curl_serve "$(host_url "$2")" "$file"
  codex_lock_set "$1" "$host_pin" "$(pin_of "$2" "$(host_url "$2")" "$file")"
}

# drop_host_pin DIR: the lock of an instance that never had the helper pin.
drop_host_pin() {
  local tmp
  tmp=$(mktemp "$DS_TEST_ROOT/lock.XXXXXX")
  jq --indent 2 'del(.agent_tools["codex-code-mode-host"])' "$1/versions.lock.json" >"$tmp"
  mv -- "$tmp" "$1/versions.lock.json"
}

# place_codex VERSION, place_host TAG: files at the destinations, as a user
# or an earlier framework version left them.
place_codex() {
  mkdir -p "${dest%/*}"
  write_codex "$1" "$dest"
}
place_host() {
  mkdir -p "${helper%/*}"
  write_host "$1" "$helper"
}

agents() {
  codex_cli "$inst" agents "$1" --profile workstation
}

downloads() { ds_call_count curl; }

# assert_session OUTPUT: a real session finds the helper.
assert_session() {
  assert_exit 0 "$dest" session
  assert_eq "code-mode-host $1" "$DS_STDOUT" "the session started the helper"
}

# run_hook STATUS INSTANCE [VAR=VALUE...]: the E2E hook, with the hook
# environment.
run_hook() {
  assert_exit "$1" env \
    DOTSTEWARD_LIB="$DS_REPO_ROOT/cli/lib" \
    DOTSTEWARD_INSTANCE="$2" \
    DOTSTEWARD_STATE_ROOT="$DS_TEST_ROOT/state" \
    DOTSTEWARD_PROFILE=workstation \
    DOTSTEWARD_PROFILE_MODE=fresh \
    DOTSTEWARD_PLATFORM=linux \
    DOTSTEWARD_COMPONENT=codex \
    DOTSTEWARD_CHECK_ONLY=1 \
    "${@:3}" "$component/e2e-code-mode-host.sh"
}

current=0.200.0
newer=0.201.0
older=0.143.0

# --- A fresh install --------------------------------------------------------------

inst=$(codex_instance fresh)
publish_codex "$inst" "$current"
publish_host "$inst" "$current"
codex_mirror "$inst"

assert_exit 1 agents check
assert_contains "$DS_STDERR" "codex $current or newer not found (found none)"
assert_exit 1 "${component}/e2e-code-mode-host.sh" --not-from-e2e
assert_contains "$DS_STDERR" "the codex E2E hook runs from dotsteward e2e"

start=$(downloads)
assert_exit 0 agents install
assert_contains "$DS_STDOUT" "codex (official-binary): downloading $(host_url "$current")"
assert_contains "$DS_STDOUT" "codex (official-binary): downloading $(codex_url "$current")"
assert_eq "$((start + 2))" "$(downloads)" "both archives downloaded"
assert_file_mode "$helper" 0755
assert_session "$current"
assert_exit 0 agents check
assert_exit 0 agents install
assert_eq "$((start + 2))" "$(downloads)" "nothing more to download"
run_hook 0 "$inst"
assert_contains "$DS_STDOUT" "[dotsteward] codex $current starts $helper"

# --- The defect: a codex without its helper ---------------------------------------

rm -f -- "$helper"
assert_exit 1 "$dest" session
assert_contains "$DS_STDERR" "failed to spawn code-mode host $helper"
assert_exit 1 agents check
assert_contains "$DS_STDERR" "codex $current needs $helper, which is missing; run 'dotsteward rebuild --profile workstation --switch'"
run_hook 1 "$inst"
assert_contains "$DS_STDERR" "codex $current needs $helper, which is missing"

# Install fetches only the helper.
start=$(downloads)
assert_exit 0 agents install
assert_eq "$((start + 1))" "$(downloads)" "only the helper downloaded"
assert_session "$current"
assert_exit 0 agents check
run_hook 0 "$inst"

# A helper that cannot start is red in the hook, which runs it.
printf '#!%s\nexit 3\n' "$BASH" >"$helper"
run_hook 1 "$inst"
assert_contains "$DS_STDERR" "$helper cannot start (exit 3)"

# A helper that is no executable file counts as missing.
rm -f -- "$helper"
: >"$helper"
assert_exit 1 agents check
assert_contains "$DS_STDERR" "codex $current needs $helper, which is missing"
rm -f -- "$helper"

# --- A helper already in place ---------------------------------------------------

# Placed by hand, no helper pin in the lock: stays, nothing is downloaded,
# every check is green; this is a machine before its lock has the pin.
inst=$(codex_instance adopted)
publish_codex "$inst" "$current"
drop_host_pin "$inst"
codex_mirror "$inst"
place_codex "$current"
place_host by-hand
before=$(sha256sum -- "$helper")
start=$(downloads)
assert_exit 0 agents check
assert_exit 0 agents install
assert_exit 0 codex_cli "$inst" install --check-only --profile workstation
run_hook 0 "$inst"
assert_eq "$before" "$(sha256sum -- "$helper")" "the placed helper is kept"
assert_eq "$start" "$(downloads)" "no download"
assert_exit 0 codex_cli "$inst" pins check

# The same machine after its lock gained the pin.
publish_host "$inst" "$current"
codex_mirror "$inst"
assert_exit 0 agents check
assert_exit 0 agents install
assert_exit 0 codex_cli "$inst" pins check
run_hook 0 "$inst"
assert_eq "$before" "$(sha256sum -- "$helper")" "the placed helper is kept with a pin"
assert_eq "$start" "$(downloads)" "no download with a pin"
assert_session by-hand

# Without the pin and without the file: red, and install names the lock key.
drop_host_pin "$inst"
codex_mirror "$inst"
rm -f -- "$helper"
assert_exit 1 agents check
assert_contains "$DS_STDERR" "codex $current needs $helper, which is missing"
assert_exit 1 agents install
assert_contains "$DS_STDERR" "versions.lock.json lacks $host_pin (required by component codex)"
[[ ! -e $helper ]] || ds_fail "a helper appeared without a pin"

# --- A pin bump moves both files together -------------------------------------------

inst=$(codex_instance bump)
publish_codex "$inst" "$current"
publish_host "$inst" "$current"
codex_mirror "$inst"
place_codex "$current"
place_host "$current"
publish_codex "$inst" "$newer"
publish_host "$inst" "$newer"
codex_mirror "$inst"
assert_exit 1 agents check
assert_contains "$DS_STDERR" "codex $newer or newer not found (found $current)"
start=$(downloads)
assert_exit 0 agents install
assert_eq "$((start + 2))" "$(downloads)" "both archives of the new release"
assert_session "$newer"
assert_eq "codex-cli $newer" "$("$dest" --version)"
assert_exit 0 agents check
backups=$(find "$DS_TEST_ROOT" "$HOME/.local/state" -path '*/files/*' -name codex-code-mode-host 2>/dev/null | wc -l)
((backups >= 1)) || ds_fail "the replaced helper was not backed up"

# The helper pin of another release is refused: one file of each release
# would not work together.
inst=$(codex_instance skew)
publish_codex "$inst" "$newer"
publish_host "$inst" "$current"
codex_mirror "$inst"
rm -f -- "$dest" "$helper"
start=$(downloads)
assert_exit 1 agents install
assert_contains "$DS_STDERR" "$host_pin is at $current but $codex_pin at $newer"
assert_eq "$start" "$(downloads)" "nothing downloaded for a pair that does not match"
[[ ! -e $dest && ! -e $helper ]] || ds_fail "files of two releases were installed"
assert_exit 1 codex_cli "$inst" pins check
assert_contains "$DS_STDOUT$DS_STDERR" "$host_pin.version"

# --- A helper archive that differs from its pin ---------------------------------------

inst=$(codex_instance tampered)
publish_codex "$inst" "$newer"
publish_host "$inst" "$newer"
codex_mirror "$inst"
place_codex "$current"
place_host "$current"
archive host evil "$DS_TEST_ROOT/evil.tar.gz"
ds_curl_serve "$(host_url "$newer")" "$DS_TEST_ROOT/evil.tar.gz"
assert_exit 1 agents install
assert_contains "$DS_STDERR" "mismatch: "
assert_eq "codex-cli $current" "$("$dest" --version)" "codex stays when its helper is refused"
assert_session "$current"

# --- A symlink at the helper's destination --------------------------------------------

inst=$(codex_instance linked-helper)
publish_codex "$inst" "$current"
publish_host "$inst" "$current"
codex_mirror "$inst"
place_codex "$current"
rm -f -- "$helper"
ln -s "$HOME/nowhere" "$helper"
assert_exit 1 agents install
assert_contains "$DS_STDERR" "refusing to replace a symlink or non-regular file: $helper"
rm -f -- "$helper"

# --- Older pins ---------------------------------------------------------------------

# Below the first version that needs it nothing asks for the helper: not the
# install, not the check, not the hook.
inst=$(codex_instance older)
publish_codex "$inst" "$older"
drop_host_pin "$inst"
codex_mirror "$inst"
rm -f -- "$dest" "$helper"
start=$(downloads)
assert_exit 0 agents install
assert_eq "$((start + 1))" "$(downloads)" "the codex archive only"
[[ ! -e $helper ]] || ds_fail "a helper was installed for an older pin"
assert_exit 0 agents check
assert_exit 0 codex_cli "$inst" pins check
run_hook 0 "$inst"
assert_contains "$DS_STDOUT" "[dotsteward] codex $older does not need codex-code-mode-host"

# The first version that needs it does.
publish_codex "$inst" 0.144.0
publish_host "$inst" 0.144.0
codex_mirror "$inst"
start=$(downloads)
assert_exit 0 agents install
assert_eq "$((start + 2))" "$(downloads)" "the first version that needs the helper"
assert_session 0.144.0
rm -f -- "$dest" "$helper"

# --- A codex from the standalone installer --------------------------------------------

# ~/.local/bin/codex is a link into its package; the helper is next to the
# link's target and the method leaves the link alone.
inst=$(codex_instance standalone)
publish_codex "$inst" "$current"
publish_host "$inst" "$current"
codex_mirror "$inst"
package=$HOME/.codex/packages/standalone/releases/$newer-$target
mkdir -p "$package/bin" "${dest%/*}"
write_codex "$newer" "$package/bin/codex"
write_host "$newer" "$package/bin/codex-code-mode-host"
ln -s "$package/bin/codex" "$dest"
start=$(downloads)
assert_exit 0 agents check
assert_exit 0 agents install
assert_eq "$start" "$(downloads)" "the standalone install is kept"
[[ -L $dest ]] || ds_fail "the link was replaced"
[[ ! -e $helper ]] || ds_fail "a second helper was installed next to the link"
assert_session "$newer"
run_hook 0 "$inst"
assert_contains "$DS_STDOUT" "[dotsteward] codex $newer starts $package/bin/codex-code-mode-host"

# The same link with its helper gone: red, and install does not write into a
# package it does not own.
rm -f -- "$package/bin/codex-code-mode-host"
assert_exit 1 agents check
assert_contains "$DS_STDERR" "codex $newer needs $package/bin/codex-code-mode-host, which is missing"
run_hook 1 "$inst"
assert_exit 1 agents install
assert_contains "$DS_STDERR" "refusing to replace a symlink or non-regular file: $dest"
[[ ! -e $package/bin/codex-code-mode-host ]] || ds_fail "the method wrote into a package it does not own"
rm -rf -- "$HOME/.codex/packages" "$dest"

# --- Another codex on PATH ----------------------------------------------------------

# A codex the method does not manage (not at the destination) keeps satisfying
# the method as before; it is not asked to have a helper next to it.
inst=$(codex_instance elsewhere)
publish_codex "$inst" "$current"
publish_host "$inst" "$current"
codex_mirror "$inst"
mkdir -p "$DS_TEST_ROOT/tools"
write_codex "$newer" "$DS_TEST_ROOT/tools/codex"
assert_exit 0 agents check
run_hook 0 "$inst"
assert_contains "$DS_STDOUT" "[dotsteward] codex at $DS_TEST_ROOT/tools/codex is not the one this method installs"
rm -f -- "$DS_TEST_ROOT/tools/codex"

# --- Report level: what else the bare binary looks for -----------------------------

# Without the package, the sandbox needs a system bwrap and search a system
# rg. Both are warnings: they matter for some sessions, not for this check.
inst=$(codex_instance reports)
publish_codex "$inst" "$current"
publish_host "$inst" "$current"
codex_mirror "$inst"
place_codex "$current"
place_host "$current"
empty=$DS_TEST_ROOT/empty-path
mkdir -p "$empty"
run_hook 0 "$inst" DOTSTEWARD_USER_PATH="$empty"
assert_contains "$DS_STDERR" "no bwrap on PATH"
assert_contains "$DS_STDERR" "no rg on PATH"
printf '#!%s\nexit 0\n' "$BASH" >"$empty/bwrap"
cp -- "$empty/bwrap" "$empty/rg"
chmod 0755 "$empty/bwrap" "$empty/rg"
run_hook 0 "$inst" DOTSTEWARD_USER_PATH="$empty"
assert_not_contains "$DS_STDERR" "no bwrap on PATH"
assert_not_contains "$DS_STDERR" "no rg on PATH"
rm -f -- "$dest" "$helper"

# --- external -----------------------------------------------------------------------

# The user installs codex and its helper: the method asks nothing and there
# is no hook.
inst=$(codex_instance external '["x86_64-linux"]' 'method = "external"')
codex_mirror "$inst"
assert_eq '[]' "$(inst_json "map (hook: hook.name) (homeOf ($(codex_expr "$inst")) \"x86_64-linux\" \"workstation\").dotsteward.components.codex.checks.e2e" | jq -c .)" \
  "no helper hook with the external method"

# --- The declaration ----------------------------------------------------------------

inst=$(codex_instance declared)
assert_eq '[{"name":"codex-code-mode-host","parallel":true,"phase":"main","profiles":null,"script":"e2e-code-mode-host.sh"}]' \
  "$(inst_json "map (hook: hook // { script = baseNameOf (toString hook.script); }) (homeOf ($(codex_expr "$inst")) \"x86_64-linux\" \"workstation\").dotsteward.components.codex.checks.e2e" | jq -cS .)"
[[ -x $component/e2e-code-mode-host.sh ]] || ds_fail "e2e-code-mode-host.sh is not executable"
