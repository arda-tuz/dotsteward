# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The guest scripts change a whole machine (sudo, Nix, a login shell), so
# they refuse to run anywhere but in a VM made by tests/vm/vm.sh: without
# the marker /etc/dotsteward-vm they stop before any command. --help works
# everywhere. Only the unattended clean install assumes "yes" for the
# package manager (SPEC D6); the agent scenarios keep the real prompts.

if [[ -e /etc/dotsteward-vm ]]; then
  printf 'note: running inside a harness VM, the refusal checks are skipped\n'
  exit 0
fi

guest=$DS_REPO_ROOT/tests/vm/guest
scenarios=(clean-install agent-prepare agent-verify)
ds_use_stubs sudo nix apt-get curl id

for scenario in "${scenarios[@]}"; do
  script=$guest/$scenario.sh
  [[ -f $script ]] || ds_fail "missing guest script: $scenario"
  bash -n "$script" || ds_fail "syntax error in $scenario"

  assert_exit 0 bash "$script" --help
  assert_contains "$DS_STDOUT" 'Usage:' "$scenario --help"

  : >"$DS_CALL_LOG"
  assert_exit 1 bash "$script"
  assert_contains "$DS_STDERR" '/etc/dotsteward-vm' "$scenario outside a VM"
  assert_calls
done
assert_exit 1 bash "$guest/clean-install.sh" --unknown-flag
assert_contains "$DS_STDERR" '/etc/dotsteward-vm'

text_of() { grep -v '^[[:space:]]*#' "$guest/$1.sh"; }
assert_contains "$(text_of clean-install)" 'export DOTSTEWARD_ASSUME_YES=1'
assert_not_contains "$(text_of agent-prepare)" 'DOTSTEWARD_ASSUME_YES'
assert_not_contains "$(text_of agent-verify)" 'DOTSTEWARD_ASSUME_YES'

# The clean install follows SPEC 12.5: the verified Nix install of stage-0,
# init of a template instance from the pushed checkout, the bootstrap
# profile, e2e, and a rollback.
clean=$(text_of clean-install)
for expected in '--install-nix-only' ' init ' '--framework-url' './bootstrap.sh --profile' ' e2e' \
  './rollback.sh --latest --apply'; do
  assert_contains "$clean" "$expected" "clean-install step"
done

# e2e has no default profile (--profile is required), so agent-verify always
# passes one: the --profile argument, else the instance's current profile
# as `dotsteward context --json` reports it.
verify=$(text_of agent-verify)
for expected in 'context --json' 'e2e --profile'; do
  assert_contains "$verify" "$expected" "agent-verify step"
done

# The shared guest helpers are not a scenario.
[[ -f $guest/common.sh ]] || ds_fail "missing guest/common.sh"
