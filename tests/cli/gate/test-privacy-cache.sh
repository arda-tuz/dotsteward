# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The gate's privacy scan with a [privacy] denylist (the static step, outside
# the sandbox) is the real `dotsteward static`: a rerun answers the unchanged
# vendored skills from the scan cache in <state root>/privacy, a vendored
# file with a denylist term still fails the step (redacted), and neither the
# denylist, its path nor a term ever reaches a Nix call, the Nix store or a
# file of the state root.
# shellcheck source=tests/cli/gate/helpers.sh
source "$DS_REPO_ROOT/tests/cli/gate/helpers.sh"

ds_use_stubs nix curl
serve_cache
# The helpers install a fake static command; this test needs the real one.
cp "$DS_REPO_ROOT/cli/commands/static.sh" "$gate_fw/cli/commands/static.sh"

term=privateterm
denylist=$DS_TEST_ROOT/private/denylist.txt
mkdir -p "$(dirname "$denylist")"
printf '# private terms\n%s\n' "$term" >"$denylist"
skill=$gate_inst/agent/skills/example-skill
mkdir -p "$skill/references"
printf -- '---\nname: example-skill\ndescription: Synthetic skill.\n---\n\n# example-skill\n' >"$skill/SKILL.md"
printf 'MIT License\n\nSynthetic license text.\n' >"$skill/LICENSE"
printf '# Guide\n\nHarmless text.\n' >"$skill/references/guide.md"
gate_config "[privacy]
denylist = \"$denylist\""

# never_private: no Nix call, no store file and no state file holds the term
# or the denylist path.
never_private() {
  local text
  for text in "$term" "$denylist"; do
    assert_not_contains "$(ds_calls_of nix)" "$text" "a Nix call names private text"
    if [[ -d $DS_STUB_STATE/nix/store ]] && grep -rqF -- "$text" "$DS_STUB_STATE/nix/store"; then
      ds_fail "the Nix store holds private text: $text"
    fi
    if grep -rqF -- "$text" "$DOTSTEWARD_STATE_ROOT"; then
      ds_fail "the state root holds private text: $text"
    fi
  done
}

assert_exit 0 run_gate --scope maintain
assert_contains "$(<"$gate_log")" "[dotsteward] scan clean: "
assert_contains "$(<"$gate_log")" " (0 from the scan cache), 0 commits"
[[ -f $DOTSTEWARD_STATE_ROOT/privacy/scan-cache ]] || ds_fail "the gate wrote no scan cache"
never_private

: >"$DS_CALL_LOG"
assert_exit 0 run_gate --scope maintain --force
assert_contains "$(<"$gate_log")" " (3 from the scan cache), 0 commits"
never_private

# A term in a cached vendored file fails the step, redacted.
printf 'mentions %s\n' "$term" >>"$skill/references/guide.md"
commit_all "docs: change the vendored guide"
: >"$DS_CALL_LOG"
assert_exit 1 run_gate --scope maintain
assert_contains "$DS_STDERR" "static       FAILED ("
assert_contains "$(<"$gate_log")" "denylist:2 agent/skills/example-skill/references/guide.md:4"
assert_not_contains "$DS_STDOUT$DS_STDERR" "$term"
assert_not_contains "$(<"$gate_log")" "$term"
assert_call_count 0 nix '* flake check *'
never_private
git -C "$gate_inst" reset -q --hard HEAD~1
assert_exit 0 run_gate --scope maintain
never_private
