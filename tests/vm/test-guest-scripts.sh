# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The guest scripts change a whole machine (sudo, Nix, vendor installers, a
# login shell), so guest_require_vm in guest/common.sh refuses to run them
# anywhere but in a VM made by tests/vm/vm.sh, before any other command: the
# marker /etc/dotsteward-vm with the text cloud-init writes, a hypervisor
# reported by systemd-detect-virt, and the VM user stranger. There is no
# override; the "inside a VM" runs below use a copy of the scripts whose
# marker path points into the test root, with the harness id stub and the
# systemd-detect-virt fake. --help works everywhere. Only the unattended
# clean install assumes "yes" for the package manager (SPEC D6); the agent
# scenarios keep the real prompts.

if [[ -e /etc/dotsteward-vm ]]; then
  printf 'note: running inside a harness VM, the refusal checks are skipped\n'
  exit 0
fi

# shellcheck source=tests/vm/testlib.sh
source "$DS_REPO_ROOT/tests/vm/testlib.sh"
vm_test_init systemd-detect-virt
guest=$DS_REPO_ROOT/tests/vm/guest
scenarios=(clean-install agent-prepare agent-verify)
ds_use_stubs sudo nix apt-get curl id claude codex

# git, tar and install are real tools the scripts use for their side
# effects; in the runs below they are traps that record the call and fail.
trap_bin=$DS_TEST_ROOT/trap-bin
mkdir -p "$trap_bin"
for tool in git tar install; do
  cat >"$trap_bin/$tool" <<EOF
#!/usr/bin/env bash
source '$DS_REPO_ROOT/tests/lib/harness.sh'
ds_record_call $tool "\$@"
exit 97
EOF
  chmod 0755 "$trap_bin/$tool"
done
side_effect_tools=(sudo nix apt-get curl claude codex git tar install)

home_listing() { (cd "$HOME" && find . -mindepth 1 | LC_ALL=C sort); }

# guest_run EXPECTED SCRIPT_DIR SCENARIO [ARG...]: runs the scenario with the
# traps first on PATH, as the current USER.
guest_run() {
  local expected=$1 dir=$2 scenario=$3
  shift 3
  assert_exit "$expected" env PATH="$trap_bin:$PATH" bash "$dir/$scenario.sh" "$@"
}

# assert_no_side_effects LABEL: no installer, git, sudo, curl or other
# side-effect tool was called and HOME holds what it held before.
assert_no_side_effects() {
  local tool
  for tool in "${side_effect_tools[@]}"; do
    assert_call_count 0 "$tool"
  done
  assert_eq "$home_before" "$(home_listing)" "HOME after $1"
}

# --- outside a VM (this host): refused before any command -----------------
home_before=$(home_listing)
for scenario in "${scenarios[@]}"; do
  script=$guest/$scenario.sh
  [[ -f $script ]] || ds_fail "missing guest script: $scenario"
  bash -n "$script" || ds_fail "syntax error in $scenario"

  assert_exit 0 bash "$script" --help
  assert_contains "$DS_STDOUT" 'Usage:' "$scenario --help"

  : >"$DS_CALL_LOG"
  guest_run 1 "$guest" "$scenario"
  assert_contains "$DS_STDERR" '/etc/dotsteward-vm' "$scenario outside a VM"
  assert_contains "$DS_STDERR" 'only inside a VM made by tests/vm/vm.sh' "$scenario outside a VM"
  assert_eq '' "$DS_STDOUT" "$scenario outside a VM prints nothing on stdout"
  assert_calls
  assert_no_side_effects "$scenario outside a VM"
done
# Arguments that would select an installer change nothing outside a VM.
for args in "agent-prepare --agent codex" "agent-prepare --agent claude" "clean-install --no-rollback" \
  "agent-verify --profile fresh" "clean-install --unknown-flag"; do
  read -r -a words <<<"$args"
  guest_run 1 "$guest" "${words[@]}"
  assert_contains "$DS_STDERR" '/etc/dotsteward-vm' "$args outside a VM"
  assert_calls
done
assert_no_side_effects "the refused runs"

# --- a simulated harness VM -------------------------------------------------
# The copy differs from the real scripts in the marker path alone.
sim=$DS_TEST_ROOT/guest-sim
sim_marker=$DS_TEST_ROOT/sim-root/etc/dotsteward-vm
mkdir -p "$sim" "$(dirname "$sim_marker")"
cp -- "$guest"/*.sh "$sim/"
sed -i "s|^guest_marker=/etc/dotsteward-vm\$|guest_marker=$sim_marker|" "$sim/common.sh"
assert_eq 1 "$(diff "$guest/common.sh" "$sim/common.sh" | grep -c '^>' || true)" "lines changed in the simulated common.sh"
assert_eq 1 "$(grep -cxF "guest_marker=$sim_marker" "$sim/common.sh" || true)" "simulated marker path"
for scenario in "${scenarios[@]}"; do
  cmp -s "$guest/$scenario.sh" "$sim/$scenario.sh" || ds_fail "the simulated $scenario differs from the real one"
done

# The text cloud-init writes into the marker (render_user_data in vm.sh).
marker_text='This machine was made by tests/vm/vm.sh (VM "sim") and is disposable.'
# shellcheck disable=SC2016 # the literal line of vm.sh, $name included
assert_contains "$(<"$DS_REPO_ROOT/tests/vm/vm.sh")" 'This machine was made by tests/vm/vm.sh (VM "$name") and is disposable.'
printf '%s\n' "$marker_text" >"$sim_marker"
# The VM user exists, and vm.sh push placed the framework checkout.
ds_passwd_set stranger /bin/bash 1001
vm_framework_repo "$HOME/dotsteward-src"
vm_fake_set systemd-detect-virt virt kvm
home_before=$(home_listing)
export USER=stranger LOGNAME=stranger

# Inside the VM the scripts pass the guard and behave as before; the
# arguments below end each scenario at its own first check, before any
# side effect.
: >"$DS_CALL_LOG"
guest_run 1 "$sim" agent-prepare
assert_contains "$DS_STDERR" '--agent claude|codex is required'
assert_not_contains "$DS_STDERR" 'only inside a VM' "agent-prepare passes the guard"
guest_run 1 "$sim" agent-prepare --agent emacs
assert_contains "$DS_STDERR" 'unknown agent: emacs (claude or codex)'
guest_run 1 "$sim" agent-verify --dir "$DS_TEST_ROOT/no-instance"
assert_contains "$DS_STDERR" "no workstation.toml in $DS_TEST_ROOT/no-instance"
guest_run 1 "$sim" clean-install --components 'BAD!'
assert_contains "$DS_STDERR" 'invalid --components: BAD!'
guest_run 1 "$sim" clean-install --dir "$HOME/dotsteward-src"
assert_contains "$DS_STDERR" "the instance directory already exists: $HOME/dotsteward-src"
for scenario in "${scenarios[@]}"; do
  guest_run 0 "$sim" "$scenario" --help
  assert_contains "$DS_STDOUT" 'Usage:' "$scenario --help in the VM"
done
assert_no_side_effects "the runs inside the simulated VM"
assert_call_count 5 systemd-detect-virt '--vm'

# refused_in_sim LABEL NEEDLE: every scenario, with installer arguments,
# refuses with NEEDLE on standard error and changes nothing.
refused_in_sim() {
  local label=$1 needle=$2 args words
  for args in "agent-prepare --agent codex" "agent-prepare --agent claude" "agent-verify" "clean-install"; do
    read -r -a words <<<"$args"
    guest_run 1 "$sim" "${words[@]}"
    assert_contains "$DS_STDERR" 'only inside a VM made by tests/vm/vm.sh' "$args $label"
    assert_contains "$DS_STDERR" "$needle" "$args $label"
    assert_eq '' "$DS_STDOUT" "$args $label prints nothing on stdout"
  done
  assert_no_side_effects "$label"
}

# A physical machine: systemd-detect-virt reports none.
vm_fake_set systemd-detect-virt virt none
refused_in_sim 'on a physical machine' 'systemd-detect-virt'
vm_fake_set systemd-detect-virt virt kvm

# Any user but stranger, root included.
USER=dotsteward-test LOGNAME=dotsteward-test refused_in_sim 'as another user' "runs as stranger, not as dotsteward-test"
DS_STUB_AS_ROOT=1 refused_in_sim 'as root' 'runs as stranger, not as root'

# A marker that cloud-init of the harness did not write, or none at all.
: >"$sim_marker"
refused_in_sim 'with an empty marker' "$sim_marker"
rm -f -- "$sim_marker"
ln -s "$DS_TEST_ROOT/elsewhere" "$sim_marker"
printf '%s\n' "$marker_text" >"$DS_TEST_ROOT/elsewhere"
refused_in_sim 'with a symlinked marker' "$sim_marker"
rm -f -- "$sim_marker"
refused_in_sim 'without the marker' "$sim_marker"
printf '%s\n' "$marker_text" >"$sim_marker"

# Without the pushed framework checkout.
mv -- "$HOME/dotsteward-src" "$DS_TEST_ROOT/moved-src"
home_before=$(home_listing)
for scenario in "${scenarios[@]}"; do
  guest_run 1 "$sim" "$scenario"
  assert_contains "$DS_STDERR" "no framework checkout at $HOME/dotsteward-src"
done
assert_no_side_effects "without the checkout"
mv -- "$DS_TEST_ROOT/moved-src" "$HOME/dotsteward-src"
export USER=dotsteward-test LOGNAME=dotsteward-test

# The guard is one function in common.sh, called by every scenario before
# its first command with side effects, with no override: the VM user is the
# one vm.sh creates and nothing in the environment can switch it off.
common=$(grep -v '^[[:space:]]*#' "$guest/common.sh")
assert_contains "$common" 'guest_require_vm() {'
assert_contains "$common" 'guest_user=stranger'
assert_contains "$(<"$DS_REPO_ROOT/tests/vm/vm.sh")" 'readonly guest_user=stranger'
assert_not_contains "$common" 'DOTSTEWARD_' "common.sh reads no DOTSTEWARD_ variable"
assert_not_contains "$common" 'DS_' "common.sh reads no harness variable"
# The guard reads its own locals and the guest_* constants, nothing else.
guard_vars=$(sed -n '/^guest_require_vm() {/,/^}/p' "$guest/common.sh" | grep -v '^[[:space:]]*#' |
  grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*' | sed -E 's/^\$\{?//' | LC_ALL=C sort -u | tr '\n' ' ')
[[ -n $guard_vars ]] || ds_fail "guest_require_vm not found in common.sh"
for var in $guard_vars; do
  case $var in
    guest_marker | guest_marker_text | guest_user | guest_src | refusal | marker_content | virt | user) ;;
    *) ds_fail "guest_require_vm reads \$$var, which the environment could set" ;;
  esac
done
for scenario in "${scenarios[@]}"; do
  first_guard=$(grep -nx 'guest_require_vm' "$guest/$scenario.sh" | head -n 1 | cut -d: -f1)
  [[ -n $first_guard ]] || ds_fail "$scenario does not call guest_require_vm"
  first_effect=$(grep -nE '^[^#]*(mktemp|mkdir|guest_step|download|export |git |curl |sudo |bash "\$)' \
    "$guest/$scenario.sh" | head -n 1 | cut -d: -f1)
  ((first_guard < first_effect)) || ds_fail "$scenario calls guest_require_vm after line $first_effect"
  sed -n "1,$((first_guard - 1))p" "$guest/$scenario.sh" | grep -v '^[[:space:]]*#' |
    grep -E '^[^#]*(mktemp|mkdir|cp |mv |rm |ln |install |git |curl |sudo |nix |>)' &&
    ds_fail "$scenario has a side effect before guest_require_vm"
done

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

# Plain e2e stops at core:repo-remote for an instance without a pushed
# origin, so the agentic test gives the agent a reachable local remote, as
# the clean install does: agent-prepare creates a bare repository and the
# suggested request names it, and agent-verify checks origin and that
# nothing is unpushed before it runs e2e.
prepare=$(text_of agent-prepare)
for expected in 'remotes/workstation.git' 'git init -q --bare' 'push main to it'; do
  assert_contains "$prepare" "$expected" "agent-prepare remote"
done
assert_not_contains "$prepare" 'instance repository local' "agent-prepare remote"
for expected in 'remote get-url origin' 'ls-remote origin'; do
  assert_contains "$verify" "$expected" "agent-verify remote"
done

# Each agent comes from its vendor's standalone installer for Linux, which
# verifies what it downloads and installs every binary the agent needs: the
# bare codex binary of a release archive lacks codex-code-mode-host, without
# which Codex 0.160 and later cannot run a single command.
for expected in 'https://claude.ai/install.sh' \
  'https://github.com/openai/codex/releases/latest/download/install.sh' 'CODEX_NON_INTERACTIVE=1'; do
  assert_contains "$prepare" "$expected" "agent-prepare installer"
done
assert_not_contains "$prepare" 'codex-x86_64-unknown-linux-musl' "agent-prepare installer"

# The printed steps name the plugin channel of the agent being prepared
# (docs/getting-started-ubuntu.md), with the local marketplace in
# ~/dotsteward-src in place of the GitHub URL.
for expected in \
  '/plugin marketplace add ~/dotsteward-src' '/plugin install dotsteward@dotsteward' \
  'codex plugin marketplace add ~/dotsteward-src' 'codex plugin add dotsteward@dotsteward'; do
  assert_contains "$prepare" "$expected" "agent-prepare plugin channel"
done
assert_not_contains "$prepare" 'the channel steps are in the framework docs' "agent-prepare plugin channel"

# The shared guest helpers are not a scenario.
[[ -f $guest/common.sh ]] || ds_fail "missing guest/common.sh"
