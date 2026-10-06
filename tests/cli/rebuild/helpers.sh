# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs and shell snippets are single-quoted on purpose
# shellcheck disable=SC2034 # the rb_* variables are read by the test files
# Helpers for the rebuild, rollback and login-shell tests (tests/cli/rebuild).
# Not a test file.
#
# Sourcing this file builds, inside DS_TEST_ROOT:
#   rb_fw        a copy of the framework under test (cli/, schema/, VERSION
#                and an empty modules/components, so the catalog is empty)
#   rb_inst      a synthetic instance, a git repository with everything
#                committed: workstation.toml (profiles "workstation", adopt
#                mode and the check profile, and "fresh", fresh mode;
#                [compat] host_input "dotfiles"), flake.nix, flake.lock,
#                versions.lock.json, an empty skills lock and the manifest
#                mirror .dotsteward/manifest.x86_64-linux.json (no
#                components, login_shell "$HOME/.nix-profile/bin/zsh", empty
#                managed links, force-linked restores and adopt paths)
#   rb_store     a stand-in for the Nix store; NIX_STORE_DIR names it
#   rb_state     the state root (DOTSTEWARD_STATE_ROOT of the harness),
#                absent until a command creates it
#   rb_hosts     <state>/host-overrides, rb_current <state>/current
#   rb_hm_profile
#                the Home Manager profile link
#                (~/.local/state/nix/profiles/home-manager), absent
#   $HOME/.nix-profile/bin/zsh
#                an executable, the stable login shell
# and replaces the nix stub's behaviour (ds_stub_override; every call is
# still recorded as "nix ARG..."):
#   --version               nix (Nix) 2.31.2
#   flake lock DIR, flake update INPUT --flake DIR
#                           write DIR/flake.lock; every write has new bytes
#                           (a counter), so a relock is visible; nothing is
#                           written while DS_TEST_ROOT/lock-noop exists
#   build INSTALLABLE...    builds a generation: a store directory whose
#                           name depends on its content (an activate script
#                           that records "activate ARG..." like a stub, so
#                           routes and overrides of "activate" apply;
#                           home-path/bin/local-maintained-files, which
#                           records "local-maintained-files ARG..." and
#                           exits with the content of DS_TEST_ROOT/lmf-exit
#                           when that file exists, left out while
#                           DS_TEST_ROOT/no-lmf exists; home-path/share/
#                           dotsteward/manifest.json, the manifest mirror at
#                           build time); prints it with --print-out-paths.
#                           DS_TEST_ROOT/build-exit makes the build fail
#                           with that status.
#
#   instance_commit MESSAGE  commits every change of the instance
#   set_config TEXT          appends TEXT to workstation.toml and commits
#   manifest_edit JQ_FILTER [JQ_OPTION...]
#                            rewrites the manifest mirror and commits
#   add_hook LIST COMPONENT NAME [PROFILES_JSON]
#                            a hook script (read from standard input) in
#                            the manifest list hooks.LIST, written to
#                            components/COMPONENT/NAME.sh; commits
#   make_generation NAME     a generation like a build makes, in the store
#                            under NAME; prints its path
#   use_generation PATH      makes PATH the active generation (the Home
#                            Manager profile link rb_hm_profile)
#   store_link PATH          a symlink at PATH into a fresh store path
#   run_rebuild ARG...       dotsteward --instance <instance> rebuild ARG...
#   run_rollback ARG...      dotsteward --instance <instance> rollback ARG...
#   run_login_shell ARG...   dotsteward --instance <instance> login-shell ARG...
#                            (standard input is empty for all three)
#   host_lock_bytes          the host flake.lock bytes (empty when absent)
#   tree_state DIR           a listing of DIR (paths, types, modes, link
#                            texts, file digests); empty when DIR is absent

rb_fw=$DS_TEST_ROOT/framework
rb_inst=$DS_TEST_ROOT/instance
rb_manifest=$rb_inst/.dotsteward/manifest.x86_64-linux.json
rb_store=$DS_TEST_ROOT/nix/store
rb_state=$DOTSTEWARD_STATE_ROOT
rb_hosts=$rb_state/host-overrides
rb_current=$rb_state/current
rb_zsh=$HOME/.nix-profile/bin/zsh
rb_hm_profile=$HOME/.local/state/nix/profiles/home-manager
export NIX_STORE_DIR=$rb_store

# The harness creates the state root empty; the commands create it, and a
# refusal must leave it absent.
rmdir -- "$rb_state"
mkdir -p "$rb_fw/modules/components" "$rb_inst/.dotsteward" "$rb_inst/agent/skills" "$rb_store" \
  "$HOME/.nix-profile/bin"
cp -R "$DS_REPO_ROOT/cli" "$DS_REPO_ROOT/schema" "$DS_REPO_ROOT/VERSION" "$rb_fw/"
printf '#!/bin/sh\nexit 0\n' >"$rb_zsh"
chmod 0755 "$rb_zsh"

cat >"$rb_inst/workstation.toml" <<'EOF'
schema_version = 1

[identity]
username = "dotsteward-test"

[instance]
name = "workstation"
remote = "git@github.com:example-org/workstation.git"

[nix]
systems = ["x86_64-linux"]
state_version = "26.05"

[profiles]
names = ["workstation", "fresh"]
default = "workstation"
check = "workstation"
bootstrap = "fresh"

[profiles.workstation]
mode = "adopt"

[profiles.fresh]
mode = "fresh"

[compat]
host_input = "dotfiles"
EOF
printf '{ outputs = { self }: { }; }\n' >"$rb_inst/flake.nix"
printf '{\n  "nodes": { "root": {} },\n  "root": "root",\n  "version": 7\n}\n' >"$rb_inst/flake.lock"
printf '{\n  "schema_version": "1.0"\n}\n' >"$rb_inst/versions.lock.json"
jq -n '{ schema_version: "1.0", expected_skill_count: 0, skills: [] }' >"$rb_inst/agent/skills.lock.json"
jq -n '{
  schema_version: 1,
  system: "x86_64-linux",
  platform: "linux",
  framework: { version: "0.0.0" },
  components: [],
  probes: [],
  checks: { commands: [], e2e: [], agents: [], floors: [] },
  hooks: {
    pre_activate: [], system_install: [], post_install: [], forbid: [],
    agents_install: [], agents_migrate: [], agents_post: [], desktop_apply: []
  },
  managed_links: [],
  force_linked_restore: [],
  adopt_paths: [],
  skill_layout: { legacy_roots: [], link_roots: {}, excluded_subtrees: [] },
  skills: { hm_root: ".agents/skills", framework: [], home_managed: [], framework_manifest: null },
  login_shell: "$HOME/.nix-profile/bin/zsh"
}' >"$rb_manifest"

instance_commit() {
  git -C "$rb_inst" add -A
  git -C "$rb_inst" commit -q --allow-empty -m "$1"
}

git -C "$rb_inst" init -q
instance_commit "initial instance"

set_config() {
  printf '\n%s\n' "$1" >>"$rb_inst/workstation.toml"
  instance_commit "configuration"
}

manifest_edit() {
  local filter=$1 tmp
  shift
  tmp=$(mktemp "$DS_TEST_ROOT/manifest.XXXXXX")
  jq "$@" "$filter" "$rb_manifest" >"$tmp"
  mv -- "$tmp" "$rb_manifest"
  instance_commit "manifest"
}

add_hook() {
  local list=$1 component=$2 name=$3 profiles=${4:-null}
  local script=$rb_inst/components/$component/$name.sh
  mkdir -p "$(dirname "$script")"
  {
    printf '#!%s\n' "$BASH"
    cat
  } >"$script"
  chmod 0755 "$script"
  manifest_edit '.hooks[$list] += [$hook]' --arg list "$list" --argjson hook "$(jq -cn \
    --arg component "$component" --arg name "$name" --argjson profiles "$profiles" \
    '{ component: $component, name: $name, phase: "main", profiles: $profiles,
       script: ("<instance>/components/" + $component + "/" + $name + ".sh") }')"
}

# The generation builder, shared by make_generation and the nix override.
rb_builder=$DS_TEST_ROOT/build-generation
cat >"$rb_builder" <<EOF
#!$BASH
# build-generation NAME: builds a generation into the test store; prints it.
set -euo pipefail
name=\$1
staging=\$(mktemp -d $(printf %q "$DS_TEST_ROOT")/staging.XXXXXX)
mkdir -p "\$staging/home-path/bin" "\$staging/home-path/share/dotsteward" "\$staging/home-files"
cat >"\$staging/activate" <<'SCRIPT'
#!$BASH
# Fake Home Manager activation script.
set -euo pipefail
source $(printf %q "$DS_REPO_ROOT/tests/lib/harness.sh")
ds_stub_begin activate "\$@"
SCRIPT
chmod 0755 "\$staging/activate"
if [[ ! -e $(printf %q "$DS_TEST_ROOT")/no-lmf ]]; then
  cat >"\$staging/home-path/bin/local-maintained-files" <<'SCRIPT'
#!$BASH
# Fake generation settings command.
set -euo pipefail
source $(printf %q "$DS_REPO_ROOT/tests/lib/harness.sh")
ds_record_call local-maintained-files "\$@"
if [[ -f \$DS_TEST_ROOT/lmf-exit ]]; then
  exit "\$(<"\$DS_TEST_ROOT/lmf-exit")"
fi
SCRIPT
  chmod 0755 "\$staging/home-path/bin/local-maintained-files"
fi
cp -- $(printf %q "$rb_manifest") "\$staging/home-path/share/dotsteward/manifest.json"
hash=\$(cd "\$staging" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -c1-32)
out=$(printf %q "$rb_store")/\$hash-\$name
if [[ -d \$out ]]; then
  rm -rf -- "\$staging"
else
  mv -- "\$staging" "\$out"
fi
printf '%s\n' "\$out"
EOF
chmod 0755 "$rb_builder"

make_generation() {
  "$rb_builder" "$1"
}

use_generation() {
  mkdir -p "$(dirname "$rb_hm_profile")"
  ln -sfn "$1" "$rb_hm_profile"
}

store_link() {
  local path=$1 target
  target=$(mktemp -d "$rb_store/XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX-home-file")
  printf 'store content\n' >"$target/file"
  mkdir -p "$(dirname "$path")"
  ln -s "$target/file" "$path"
}

ds_use_stubs nix sudo chsh getent
ds_stub_override nix <<EOF
#!$BASH
# nix override of the rebuild tests (see tests/cli/rebuild/helpers.sh).
set -euo pipefail
while ((\$#)); do
  case \$1 in
    --extra-experimental-features) shift 2 ;;
    -L | --print-build-logs) shift ;;
    *) break ;;
  esac
done
write_lock() {
  local counter=$(printf %q "$DS_TEST_ROOT")/lock-counter n=0
  [[ ! -e $(printf %q "$DS_TEST_ROOT")/lock-noop ]] || return 0
  [[ -f \$counter ]] && n=\$(<"\$counter")
  n=\$((n + 1))
  printf '%s\n' "\$n" >"\$counter"
  printf '{ "host-lock": %s }\n' "\$n" >"\$1/flake.lock"
}
case \${1:-} in
  --version) printf 'nix (Nix) 2.31.2\n' ;;
  flake)
    case \${2:-} in
      lock) write_lock "\$3" ;;
      update)
        [[ \${4:-} == --flake ]] || { echo "nix override: unexpected flake update arguments: \$*" >&2; exit 1; }
        write_lock "\$5"
        ;;
      *) echo "nix override: unsupported: \$*" >&2; exit 1 ;;
    esac
    ;;
  build)
    if [[ -f $(printf %q "$DS_TEST_ROOT")/build-exit ]]; then
      echo "error: builder failed" >&2
      exit "\$(<$(printf %q "$DS_TEST_ROOT")/build-exit)"
    fi
    out=\$($(printf %q "$rb_builder") home-manager-generation)
    if [[ " \$* " == *" --print-out-paths "* ]]; then
      printf '%s\n' "\$out"
    fi
    ;;
  *) echo "nix override: unsupported: \$*" >&2; exit 1 ;;
esac
EOF

run_rebuild() {
  "$rb_fw/cli/dotsteward" --instance "$rb_inst" rebuild "$@" </dev/null
}

run_rollback() {
  "$rb_fw/cli/dotsteward" --instance "$rb_inst" rollback "$@" </dev/null
}

run_login_shell() {
  "$rb_fw/cli/dotsteward" --instance "$rb_inst" login-shell "$@" </dev/null
}

host_lock_bytes() {
  if [[ -f $rb_hosts/flake.lock ]]; then
    cat -- "$rb_hosts/flake.lock"
  fi
}

tree_state() {
  [[ -e $1 ]] || return 0
  (
    cd "$1" || exit
    find . -mindepth 1 -printf '%p %y %m %l\n' | LC_ALL=C sort
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
  )
}
