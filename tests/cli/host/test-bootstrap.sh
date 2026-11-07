# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# `bootstrap --stage 1` names the machine first and publishes its host file last. Naming
# commits nothing, so the checkout stays clean and the E2E run of stage 1 passes; no git
# identity is needed; and a publish that cannot reach the remote does not fail the
# bootstrap. An instance that names no machine and has nobody to ask goes on as today.
# The install, rebuild and login-shell steps are recording stand-ins (their own suites
# cover them); agents, hosts, e2e and the instance lock are real.
# shellcheck source=tests/cli/host/helpers.sh
source "$DS_REPO_ROOT/tests/cli/host/helpers.sh"

for command in install rebuild login-shell; do
  {
    printf '# summary: stand-in %s of the bootstrap tests\n' "$command"
    printf 'source %q\n' "$DS_REPO_ROOT/tests/lib/harness.sh"
    printf 'ds_record_call dotsteward-%s "$@"\n' "$command"
    # A rebuild installs the skills of this machine, as the real one does.
    if [[ $command == rebuild ]]; then
      printf '%q --instance %q agents install --profile fresh --skip-validation\n' "$agents_fw/cli/dotsteward" "$agents_inst"
    fi
  } >"$agents_fw/cli/commands/$command.sh"
done
real_e2e=$DS_TEST_ROOT/e2e.real
cp -- "$agents_fw/cli/commands/e2e.sh" "$real_e2e"

ds_bootstrap() {
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" bootstrap --profile fresh --stage 1 "$@"
}

run_bootstrap() {
  ds_bootstrap "$@" </dev/null
}

remote_tip() {
  git -C "$e2e_bare" rev-parse refs/heads/main
}

head=$(git -C "$agents_inst" rev-parse HEAD)
final="[dotsteward] bootstrap complete for profile fresh; log out and back in once so the new login shell and desktop session take effect"

clean_and_still() {
  assert_eq "$head" "$(git -C "$agents_inst" rev-parse HEAD)" "the bootstrap moved the checkout"
  assert_eq "" "$(git -C "$agents_inst" status --porcelain --untracked-files=normal)" "the bootstrap changed the checkout"
}

record() {
  jq -c "$1" "$(machine_file)"
}

# --- an instance that names no machine, and nobody to ask -------------------------------

bare_before=$(remote_tip)
assert_exit 0 run_bootstrap
assert_eq "$final" "$(tail -n 1 <<<"$DS_STDOUT")"
assert_contains "$DS_STDOUT" "dotsteward host init --name"
assert_calls \
  "dotsteward-install --profile fresh" \
  "dotsteward-rebuild --profile fresh --switch" \
  "dotsteward-login-shell set --profile fresh"
[[ ! -e $(machine_file) && ! -e $agents_inst/hosts ]] || ds_fail "the bootstrap named the machine"
assert_eq "$bare_before" "$(remote_tip)" "the bootstrap pushed"
clean_and_still

# --- an instance that names no machine, and a name ----------------------------------------

# The machine has its name here, and the remote stays as it is: a first host file is not
# for the end of a bootstrap, because an older instance may hold its tree to a list of
# files. Registering it is one command, when the instance is ready for it.
bare_before=$(remote_tip)
: >"$DS_CALL_LOG"
assert_exit 0 env DOTSTEWARD_MACHINE=laptop "$agents_fw/cli/dotsteward" --instance "$agents_inst" \
  bootstrap --profile fresh --stage 1 </dev/null
assert_eq "$final" "$(tail -n 1 <<<"$DS_STDOUT")"
assert_eq '"laptop"' "$(record .name)"
assert_contains "$DS_STDOUT" "'dotsteward host publish' registers it"
assert_not_contains "$DS_STDOUT" "published"
assert_eq "$bare_before" "$(remote_tip)" "the bootstrap registered the first machine"
clean_and_still
rm -- "$(machine_file)"
assert_exit 0 env DOTSTEWARD_ASSUME_YES=1 "$agents_fw/cli/dotsteward" --instance "$agents_inst" \
  bootstrap --profile fresh --stage 1 </dev/null
assert_not_contains "$DS_STDOUT" "published"
assert_eq "$bare_before" "$(remote_tip)" "the bootstrap registered the first machine"
rm -- "$(machine_file)"

# --- an instance with a producer: the file lands at the end ----------------------------------

printf '\n[hosts]\nproducer = "laptop"\n' >>"$agents_inst/workstation.toml"
publish_instance "chore(hosts): name the producer"
head=$(git -C "$agents_inst" rev-parse HEAD)
bare_before=$(remote_tip)
: >"$DS_CALL_LOG"
assert_exit 0 env DOTSTEWARD_MACHINE=laptop "$agents_fw/cli/dotsteward" --instance "$agents_inst" \
  bootstrap --profile fresh --stage 1 </dev/null
assert_eq "$final" "$(tail -n 1 <<<"$DS_STDOUT")"
assert_contains "$DS_STDOUT" "this machine is laptop"
assert_contains "$DS_STDOUT" "e2e checks passed (profile fresh)"
assert_contains "$DS_STDOUT" "published hosts/laptop.toml"
# It runs first: the record exists, with the profile of the bootstrap.
assert_eq '"laptop"' "$(record .name)"
assert_eq '"fresh"' "$(record .host.profile)"
# Stage 1 commits nothing: the checkout never moved, the file is on the remote.
clean_and_still
assert_contains "$(git -C "$e2e_bare" show refs/heads/main:hosts/laptop.toml)" 'profile = "fresh"'
assert_eq "$bare_before" "$(git -C "$e2e_bare" rev-parse "$(remote_tip)^")"
# Behind the remote afterwards, and that is no failure of the machine.
assert_exit 0 run_e2e
assert_contains "$DS_STDOUT" "1 commit behind origin main"
git -C "$agents_inst" pull -q --ff-only origin main
head=$(git -C "$agents_inst" rev-parse HEAD)
rm -- "$(machine_file)"

# --- an instance with names wants one -------------------------------------------------------

: >"$DS_CALL_LOG"
assert_exit 2 run_bootstrap
assert_contains "$DS_STDERR" "this machine has no name yet"
assert_contains "$DS_STDERR" "bootstrap stopped: dotsteward host failed (exit 2)"
assert_calls
assert_not_contains "$DS_STDOUT" "bootstrap complete"

# The name of another machine takes --reuse, also through the environment.
assert_exit 1 env DOTSTEWARD_MACHINE=laptop "$agents_fw/cli/dotsteward" --instance "$agents_inst" \
  bootstrap --profile fresh --stage 1 </dev/null
assert_contains "$DS_STDERR" "--reuse"
assert_contains "$DS_STDERR" "DOTSTEWARD_MACHINE_REUSE=1"
assert_calls

# A reinstall without a terminal goes through ./bootstrap.sh, which takes no such option:
# the environment says it is one.
assert_exit 0 env DOTSTEWARD_MACHINE=laptop DOTSTEWARD_MACHINE_REUSE=1 \
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" bootstrap --profile fresh --stage 1 </dev/null
assert_eq "$final" "$(tail -n 1 <<<"$DS_STDOUT")"
assert_eq '"laptop"' "$(record .name)"
assert_contains "$DS_STDOUT" "nothing to publish"
rm -- "$(machine_file)"
: >"$DS_CALL_LOG"

# A reinstall under the same name: named beforehand, the bootstrap keeps it. What the
# name stands for comes back, and the file that says so does not change.
lock_add alpha
set_machines alpha '["laptop"]'
lock_add beta
write_host laptop 'declined = { skills = ["beta"] }'
publish_instance "chore: scope"
head=$(git -C "$agents_inst" rev-parse HEAD)
assert_exit 0 run_host init --name laptop --reuse
assert_eq '"laptop"' "$(effective .name)"
assert_eq '["beta"]' "$(effective .skip.skills)"
: >"$DS_CALL_LOG"
assert_exit 0 run_bootstrap
[[ -f $HOME/.agents/skills/alpha/SKILL.md && ! -e $HOME/.agents/skills/beta ]] ||
  ds_fail "agents install does not follow the name"
assert_contains "$DS_STDOUT" "this machine is laptop"
assert_contains "$DS_STDOUT" "published hosts/laptop.toml"
assert_contains "$(git -C "$e2e_bare" show refs/heads/main:hosts/laptop.toml)" 'declined = { skills = ["beta"] }'
git -C "$agents_inst" pull -q --ff-only origin main
head=$(git -C "$agents_inst" rev-parse HEAD)

# Run again: nothing asks, nothing new.
bare_before=$(remote_tip)
assert_exit 0 run_bootstrap
assert_contains "$DS_STDOUT" "nothing to publish"
assert_eq "$bare_before" "$(remote_tip)"
rm -- "$(machine_file)"

# --- on a terminal ---------------------------------------------------------------------------

# The question comes through the instance lock and the steps, standard input intact.
# Another machine gets neither what is scoped to the laptop nor a question about it.
rm -rf -- "$HOME/.agents/skills/alpha" "$HOME/.claude/skills/alpha"
: >"$DS_CALL_LOG"
assert_exit 0 on_tty 'second' bootstrap --profile fresh --stage 1
assert_contains "$DS_STDOUT" "Machines of this instance: laptop."
assert_contains "$DS_STDOUT" "published hosts/second.toml"
assert_eq '"second"' "$(record .name)"
assert_eq '"fresh"' "$(record .host.profile)"
[[ ! -e $HOME/.agents/skills/alpha && -f $HOME/.agents/skills/beta/SKILL.md ]] ||
  ds_fail "another machine does not follow its own name"
assert_calls \
  "dotsteward-install --profile fresh" \
  "dotsteward-rebuild --profile fresh --switch" \
  "dotsteward-login-shell set --profile fresh"
git -C "$agents_inst" pull -q --ff-only origin main
head=$(git -C "$agents_inst" rev-parse HEAD)
rm -- "$(machine_file)"

# --- no git identity ----------------------------------------------------------------------------

# A fresh machine has none: nothing in stage 1 needs one, and the commit of the host file
# takes the author of the tip. No configuration is written.
assert_exit 0 env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null DOTSTEWARD_MACHINE=third \
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" host init </dev/null
assert_exit 0 env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" bootstrap --profile fresh --stage 1 </dev/null
assert_contains "$DS_STDOUT" "published hosts/third.toml"
assert_eq "$DS_TEST_IDENTITY_NAME" "$(git -C "$e2e_bare" log -1 --format=%an "$(remote_tip)")"
assert_eq "" "$(git -C "$agents_inst" config --local --get user.name || true)"
git -C "$agents_inst" pull -q --ff-only origin main
head=$(git -C "$agents_inst" rev-parse HEAD)
rm -- "$(machine_file)"

# --- nothing fails the bootstrap at the end -------------------------------------------------------

# No network or no login yet: the machine is installed, and the file waits. A stand-in
# e2e here, since the real one needs the remote as well.
{
  printf '# summary: stand-in e2e of the bootstrap tests\n'
  printf 'source %q\n' "$DS_REPO_ROOT/tests/lib/harness.sh"
  printf 'ds_record_call dotsteward-e2e "$@"\n'
} >"$agents_fw/cli/commands/e2e.sh"
bare_before=$(remote_tip)
assert_exit 0 env DOTSTEWARD_MACHINE=fourth DOTSTEWARD_ASSUME_YES=1 DS_FAKESSH_FAIL=1 \
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" bootstrap --profile fresh --stage 1 </dev/null
assert_eq "$final" "$(tail -n 1 <<<"$DS_STDOUT")"
assert_contains "$DS_STDERR" "hosts/fourth.toml waits"
assert_contains "$DS_STDERR" "dotsteward host publish"
assert_eq "$bare_before" "$(remote_tip)"
clean_and_still
assert_eq '"fourth"' "$(record .name)"
cp -- "$real_e2e" "$agents_fw/cli/commands/e2e.sh"

# ... and lands with the next one.
assert_exit 0 run_host publish
assert_contains "$DS_STDOUT" "published hosts/fourth.toml"
git -C "$agents_inst" pull -q --ff-only origin main
head=$(git -C "$agents_inst" rev-parse HEAD)

# The remote refuses: the same, with the reason.
hook=$e2e_bare/hooks/pre-receive
printf '#!%s\nexit 1\n' "$BASH" >"$hook"
chmod 0755 "$hook"
assert_exit 0 run_host init --tags refused
assert_exit 0 run_bootstrap
assert_eq "$final" "$(tail -n 1 <<<"$DS_STDOUT")"
assert_contains "$DS_STDERR" "the remote refused the push"
assert_contains "$DS_STDERR" "dotsteward host publish"
rm -- "$hook"

# A failed step before the end stops the bootstrap, and nothing is published.
printf 'exit 7\n' >>"$agents_fw/cli/commands/rebuild.sh"
bare_before=$(remote_tip)
assert_exit 7 run_bootstrap
assert_contains "$DS_STDERR" "bootstrap stopped: dotsteward rebuild failed (exit 7)"
assert_not_contains "$DS_STDOUT" "published"
assert_eq "$bare_before" "$(remote_tip)"
