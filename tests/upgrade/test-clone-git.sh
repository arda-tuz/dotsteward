# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from the harness and the helpers
# The clone of the writer behaves as the checkout would: the hooks of the checkout run on its push,
# from .git/hooks as from a core.hooksPath relative to the checkout, and its local settings hold, a
# pushurl and commit signing among them. A hook or a pushurl that refuses leaves the remote where it
# was.
# shellcheck source=tests/upgrade/helpers.sh
source "$DS_REPO_ROOT/tests/upgrade/helpers.sh"

tool_stub fwupdmgr 'exit 2'
tool_stub claude 'case "$1" in --version) printf "2.0.0 (Claude Code)\n";; esac'
answer='Update these too=n'

run_quiet() {
  on_terminal "$answer" -- --tracked >"$DS_TEST_ROOT/run.out" 2>&1 || true
}

# --- .git/hooks/pre-push of the checkout --------------------------------------------------------
printf '#!/bin/sh\necho "local hook ran" >>%s\necho "the local hook says no" >&2\nexit 1\n' "$DS_TEST_ROOT/hook.log" \
  >"$up_inst/.git/hooks/pre-push"
chmod 0755 "$up_inst/.git/hooks/pre-push"
move example.one 2.0 pypi
before=$(remote_oid)
run_quiet
assert_eq "$before" "$(remote_oid)" "the hook of the checkout refused the push"
assert_contains "$(<"$DS_TEST_ROOT/hook.log")" "local hook ran"
last_report '[.items[] | select(.code == "publish-refused")] | length == 1'
rm -f "$up_inst/.git/hooks/pre-push" "$DS_TEST_ROOT/hook.log"

# --- a core.hooksPath relative to the checkout, in a directory git does not track -------------
mkdir -p "$up_inst/.local-hooks"
printf '.local-hooks/\n' >>"$up_inst/.git/info/exclude"
printf '#!/bin/sh\necho "relative hook ran" >>%s\nexit 1\n' "$DS_TEST_ROOT/hook.log" >"$up_inst/.local-hooks/pre-push"
chmod 0755 "$up_inst/.local-hooks/pre-push"
git -C "$up_inst" config core.hooksPath .local-hooks
move example.two 2.0 pypi
before=$(remote_oid)
run_quiet
assert_eq "$before" "$(remote_oid)"
assert_contains "$(<"$DS_TEST_ROOT/hook.log")" "relative hook ran"
git -C "$up_inst" config --unset core.hooksPath
rm -f "$DS_TEST_ROOT/hook.log"

# --- a pushurl that goes nowhere --------------------------------------------------------------
git -C "$up_inst" config remote.origin.pushurl "$DS_TEST_ROOT/nowhere.git"
move example.three 2.0 pypi
before=$(remote_oid)
run_quiet
assert_eq "$before" "$(remote_oid)" "the push goes to the pushurl"
git -C "$up_inst" config --unset remote.origin.pushurl

# --- commit signing ---------------------------------------------------------------------------
cat >"$DS_TEST_ROOT/fake-gpg" <<'GPG'
#!/bin/sh
cat >/dev/null
printf '\n[GNUPG:] SIG_CREATED D 1 8 00 0 0\n' >&2
printf -- '-----BEGIN PGP SIGNATURE-----\n\nZmFrZQ==\n-----END PGP SIGNATURE-----\n'
GPG
chmod 0755 "$DS_TEST_ROOT/fake-gpg"
git -C "$up_inst" config gpg.program "$DS_TEST_ROOT/fake-gpg"
git -C "$up_inst" config commit.gpgsign true
move example.four 2.0 pypi
assert_exit 0 on_terminal "$answer" -- --tracked
assert_eq 2.0 "$(git -C "$up_bare" show refs/heads/main:versions.lock.json | jq -r '."example.four"')"
assert_contains "$(git -C "$up_bare" cat-file commit refs/heads/main)" "gpgsig -----BEGIN PGP SIGNATURE-----"
