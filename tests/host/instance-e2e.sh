#!/usr/bin/env bash
# Instance E2E with real Nix: a new instance from the framework
# template, built and given a settings round trip, all inside a temporary
# HOME and never activated. It runs on a developer machine with Nix and on
# CI.
#
# Usage: bash tests/host/instance-e2e.sh [--help]
#
# Steps, the first failure stops the run:
#   1. template: `nix flake init -t path:<checkout>` fills ~/workstation with
#      the template (the `# dotsteward:template` marker is present);
#   2. init: `dotsteward init` of this checkout fills that directory in place
#      with the catalog components shell, herdr, claude-code, codex and
#      opencode-pi and the framework input path:<checkout>, gives the
#      launcher and wrappers back the executable bit `nix flake init` drops,
#      and commits it;
#   3. publish: the instance is pushed to a local bare remote, which is
#      origin and therefore settings.published_ref;
#   4. build: `rebuild --build-only` through the instance launcher; the
#      built generation holds the managed files and the local-maintained-files
#      alias, the flake.lock and the tree stay unchanged, and nothing is
#      activated (no managed file and no Home Manager state in HOME);
#   5. settings round through the generation's local-maintained-files alias:
#      track a key of the claude-settings target in HOME, publish it, change
#      it live and flush it, apply it on a second home (a clone of the remote,
#      first contact), change it there and bring it back with apply;
#   6. the real user's Home Manager and Nix profile state is unchanged.
#
# Environment (tests/host/lib.sh): DS_HOST_TIMEOUT bounds the whole run in
# seconds (default 3600); DS_HOST_FRAMEWORK_URL replaces the framework flake
# reference path:<checkout>.
set -Eeuo pipefail

framework_root=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/host/lib.sh
source "$framework_root/tests/host/lib.sh"
host_e2e_init "${BASH_SOURCE[0]}" "$@"

components=shell,herdr,claude-code,codex,opencode-pi
profile=workstation
instance=$HOME/workstation
remote=$DS_TEST_ROOT/remote/workstation.git
second_home=$DS_TEST_ROOT/second-home
second_instance=$second_home/workstation
second_state=$DS_TEST_ROOT/second-state
settings_file=.claude/settings.json

# lmf_first ARG...: the generation's alias with its baked defaults (the
# instance checkout ~/workstation, the state root of the environment).
lmf_first() {
  host_lmf "$@"
}

# lmf_second ARG...: the same alias for the second home and its clone.
lmf_second() {
  host_lmf --home "$second_home" --repo "$second_instance" --state-dir "$second_state" "$@"
}

# entry_field STATUS_JSON FILTER: the jq FILTER (.state, .base.value) of the
# claude-theme row, raw.
entry_field() {
  jq -r '.entries[] | select(.id == "claude-theme") | '"$2" <<<"$1"
}

# set_theme FILE VALUE: rewrites the theme key of a settings file.
set_theme() {
  local updated
  updated=$(jq --arg value "$2" '.theme = $value' "$1")
  printf '%s\n' "$updated" >"$1"
}

# commit_settings REPO MESSAGE: commits the settings buffer and pushes it.
commit_settings() {
  git -C "$1" add -A
  git -C "$1" commit -q -m "$2"
  git -C "$1" push -q origin main
}

step_template() {
  mkdir -p "$instance"
  (cd "$instance" && host_nix flake init -t "$DS_HOST_FRAMEWORK_URL")
  assert_contains "$(<"$instance/workstation.toml")" '# dotsteward:template' "the template marker"
  [[ -f $instance/.dotsteward/cli.sh ]] || ds_fail "the template has no launcher"
}

step_init() {
  host_framework_cli init \
    --dir "$instance" \
    --remote "$remote" \
    --components "$components" \
    --framework-url "$DS_HOST_FRAMEWORK_URL" \
    --non-interactive --json >"$DS_TEST_ROOT/init.json"
  assert_json "$DS_TEST_ROOT/init.json" '.components == ["shell","herdr","claude-code","codex","opencode-pi"]'
  assert_json "$DS_TEST_ROOT/init.json" '.commit | test("^[0-9a-f]{40}$")'
  assert_not_contains "$(<"$instance/workstation.toml")" '# dotsteward:template' "the template marker after init"
  assert_contains "$(<"$instance/workstation.toml")" "username = \"$USER\"" "the identity"
  assert_contains "$(<"$instance/flake.nix")" "$DS_HOST_FRAMEWORK_URL" "the framework input"
  [[ -f $instance/flake.lock ]] || ds_fail "init wrote no flake.lock"
  local script
  for script in .dotsteward/cli.sh rebuild.sh rollback.sh update.sh bootstrap.sh; do
    [[ -x $instance/$script ]] || ds_fail "not executable after init: $script"
    assert_eq 100755 "$(git -C "$instance" ls-files -s -- "$script" | cut -d' ' -f1)" "the committed mode of $script"
  done
  assert_eq "chore: initialize dotsteward instance" "$(git -C "$instance" log -1 --format=%s)"
  assert_eq "" "$(git -C "$instance" status --porcelain)" "the instance tree after init"
}

step_publish() {
  mkdir -p "$(dirname "$remote")"
  ds_bare_remote "$remote" "$instance"
  git -C "$instance" branch -q --set-upstream-to=origin/main main
  assert_eq "$(git -C "$instance" rev-parse HEAD)" "$(git -C "$remote" rev-parse main)"
}

step_build() {
  local lock_before activation
  lock_before=$(sha256sum "$instance/flake.lock")
  host_instance_cli rebuild --profile "$profile" --build-only
  activation=$(host_built_activation)
  [[ $activation == /nix/store/* && -x $activation/activate ]] ||
    ds_fail "no built activation package: $activation"
  [[ -x $activation/home-path/bin/local-maintained-files ]] ||
    ds_fail "the generation has no local-maintained-files alias"
  [[ -x $activation/home-path/bin/dotsteward ]] || ds_fail "the generation has no dotsteward CLI"
  [[ -e $activation/home-files/.zshrc ]] || ds_fail "the generation manages no .zshrc"
  [[ -e $activation/home-files/.claude/CLAUDE.md ]] || ds_fail "the generation has no agent rules"
  assert_eq "$profile" "$(<"$DOTSTEWARD_STATE_ROOT/current/profile")" "the recorded profile"
  assert_eq "$lock_before" "$(sha256sum "$instance/flake.lock")" "the instance flake.lock"
  assert_eq "" "$(git -C "$instance" status --porcelain)" "the instance tree after the build"
  host_assert_not_activated "$HOME"
}

step_settings_track() {
  local status
  mkdir -p "$HOME/.claude"
  printf '{\n  "theme": "dark",\n  "verbose": false\n}\n' >"$HOME/$settings_file"
  lmf_first track --id claude-theme --target claude-settings --key theme
  assert_contains "$(<"$instance/local-maintained-files/buffer.toml")" 'claude-theme'
  commit_settings "$instance" "chore(settings): track the theme"
  lmf_first reconcile
  status=$(lmf_first status --json)
  assert_eq in-sync "$(entry_field "$status" .state)" "after track and reconcile"
  assert_eq dark "$(entry_field "$status" .base.value)" "the published base"
}

step_settings_flush() {
  local status
  set_theme "$HOME/$settings_file" light
  status=$(lmf_first status --json)
  assert_eq local-changed "$(entry_field "$status" .state)" "after a live change"
  lmf_first flush
  assert_contains "$(<"$instance/local-maintained-files/buffer.toml")" '"light"' "the flushed value"
  commit_settings "$instance" "chore(settings): theme light"
  lmf_first reconcile
  status=$(lmf_first status --json)
  assert_eq in-sync "$(entry_field "$status" .state)" "after flush and reconcile"
  assert_eq light "$(entry_field "$status" .base.value)" "the published base after flush"
  assert_exit 0 lmf_first verify
}

step_settings_second_home() {
  local status
  mkdir -p "$second_home"
  git clone -q "$remote" "$second_instance"
  [[ ! -e $second_home/$settings_file ]] || ds_fail "the second home is not empty"
  status=$(lmf_second status --json)
  assert_eq first-contact "$(entry_field "$status" .state)" "on the second home"
  lmf_second apply
  assert_eq light "$(jq -r .theme "$second_home/$settings_file")" "the applied value"
  assert_file_mode "$second_home/$settings_file" 0644
  assert_exit 0 lmf_second verify
  host_assert_not_activated "$second_home"
}

step_settings_back() {
  local status
  set_theme "$second_home/$settings_file" auto
  lmf_second flush
  commit_settings "$second_instance" "chore(settings): theme auto"
  lmf_second reconcile
  git -C "$instance" pull -q --ff-only
  status=$(lmf_first status --json)
  assert_eq remote-changed "$(entry_field "$status" .state)" "after the second home published"
  lmf_first apply
  assert_eq auto "$(jq -r .theme "$HOME/$settings_file")" "the value from the second home"
  assert_eq false "$(jq -r .verbose "$HOME/$settings_file")" "an untracked key"
  lmf_first reconcile
  assert_exit 0 lmf_first verify
  assert_exit 0 lmf_first validate
  assert_eq "" "$(git -C "$instance" status --porcelain)" "the instance tree after the settings round"
}

host_step "Template (nix flake init -t)" step_template
host_step "dotsteward init" step_init
host_step "Publish the instance to a local bare remote" step_publish
host_step "rebuild --build-only" step_build
host_step "Settings: track and publish" step_settings_track
host_step "Settings: live change and flush" step_settings_flush
host_step "Settings: apply on a second home" step_settings_second_home
host_step "Settings: back to the first home" step_settings_back
host_step "The real user's profiles are unchanged" host_assert_real_profiles_unchanged
host_log "the instance was created, built and given a settings round trip without activation"
