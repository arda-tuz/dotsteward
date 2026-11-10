# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# What the owner does with apt by hand never turns core:apt-files red. After the first terminal run
# wrote the pin file, the owner purges the NVIDIA stack, or installs a driver on a machine that had
# none, and the dpkg hook rewrites the pairs: the pairs are what dpkg has, the header is there, and
# only the rule (which classes the file holds back) is not yet what the next terminal `upgrade`
# writes. That is a note. A pin file whose pairs are not what dpkg has (the hook did not run, or a
# hand edit) is the one finding. `check-files` prints KIND CODE PATH MESSAGE, tab separated.
# shellcheck source=tests/apt-worlds/helpers.sh
source "$DS_REPO_ROOT/tests/apt-worlds/helpers.sh"
world_require

policy() {
  APT_CONFIG=$WORLD/apt.conf DOTSTEWARD_APT_SUDO='' ds_python dotsteward_cli.apt_plan policy --request - \
    <<<'{}' >/dev/null 2>"$DS_TEST_ROOT/policy.err" || ds_fail "policy failed: $(<"$DS_TEST_ROOT/policy.err")"
}
check() {
  CHECK=$(APT_CONFIG=$WORLD/apt.conf ds_python dotsteward_cli.apt_plan check-files --request - <<<"${1:-{\}}" 2>&1) ||
    ds_fail "check-files failed: $CHECK"
}
run_hook() {
  local hook
  hook=$(sed -n 's/^post-invoke="\(.*\)"$/\1/p' "$WORLD/etc/dpkg/dpkg.cfg.d/60dotsteward-pin")
  hook=${hook% >/dev/null 2>&1 || true}
  eval "$hook" || ds_fail "the dpkg hook failed"
}
# list_files: the list files of every package, as a real dpkg database has them.
list_files() {
  local name
  mkdir -p "$WORLD/var/lib/dpkg/info"
  for name in $(dpkg-query --admindir="$WORLD/var/lib/dpkg" -W -f='${binary:Package}\n'); do
    : >"$WORLD/var/lib/dpkg/info/$name.list"
    : >"$WORLD/var/lib/dpkg/info/$name.md5sums"
  done
}
findings() {
  grep -c '^finding' <<<"$CHECK" || true
}

# --- the owner purges the NVIDIA stack --------------------------------------------------------
world_up no-change
with_driver=$DS_TEST_ROOT/status.with-driver
cp "$WORLD/var/lib/dpkg/status" "$with_driver"
real=$WORLD/etc/apt/preferences.d/60dotsteward
list_files
policy
check
assert_eq "" "$CHECK" "after policy there is nothing to say"
python3 - "$WORLD/var/lib/dpkg/status" <<'PY'
import re
import sys

path = sys.argv[1]
stanzas = open(path, encoding="utf-8").read().rstrip("\n").split("\n\n")


def gone(stanza):
    name = re.search(r"^Package: (.*)$", stanza, re.M).group(1)
    source = (re.search(r"^Source: (\S+)", stanza, re.M) or re.search(r"^Package: (\S+)", stanza, re.M)).group(1)
    return "nvidia" in name or source.startswith(("nvidia-graphics-drivers", "linux-restricted"))


open(path, "w", encoding="utf-8").write("\n\n".join(s for s in stanzas if not gone(s)) + "\n")
PY
list_files
run_hook
check
assert_eq 0 "$(findings)" "the purge of the owner is no finding: $CHECK"
assert_contains "$CHECK" $'note\tapt-file-rule\t'"$real"
assert_contains "$CHECK" "the next 'dotsteward upgrade' on a terminal sets it"

# A pin file whose pairs are not what dpkg has: the hook did not run after a dpkg call.
cp "$with_driver" "$WORLD/var/lib/dpkg/status"
list_files
check
assert_contains "$CHECK" $'finding\tapt-file-mismatch\t'"$real"

# --- the owner installs a driver on a machine with the kernel class only -------------------------
world_up no-nvidia
real=$WORLD/etc/apt/preferences.d/60dotsteward
list_files
policy
assert_not_contains "$(<"$real")" "nvidia-graphics-drivers"
cp "$with_driver" "$WORLD/var/lib/dpkg/status"
list_files
run_hook
check
assert_eq 0 "$(findings)" "the driver the owner installed is no finding: $CHECK"
assert_contains "$CHECK" $'note\tapt-file-rule\t'"$real"

# [apt.gated] enable = false while the file is there: a note, the next terminal run removes it.
check '{"gated": false}'
assert_eq 0 "$(findings)" "a pin file the machine no longer wants is no finding: $CHECK"
assert_contains "$CHECK" $'note\tapt-file-unwanted\t'"$real"
