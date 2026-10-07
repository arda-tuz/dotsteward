# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Helpers for the instance launcher tests (tests/cli/launcher).
#
# The launcher under test is template/.dotsteward/cli.sh; every fixture
# instance gets a byte copy of it at .dotsteward/cli.sh, exactly as an
# instance carries it.
#
# Fast tests (launcher_use_stub_nix) run against the nix stub of
# tests/lib/stubs: its fake build output gets a recording bin/dotsteward
# through the stub's output template, and a nix-store shim written here
# registers the "GC root" by creating the symlink. The dirty-tree test
# (launcher_use_real_nix) runs the real Nix against an isolated store inside
# DS_TEST_ROOT, so it never touches the host store or its GC roots.

launcher_template=$DS_REPO_ROOT/template/.dotsteward/cli.sh

# launcher_instance DIR: creates an instance checkout at DIR (a git
# repository with one commit) holding workstation.toml, flake.nix,
# flake.lock, components/alpha/default.nix and .dotsteward/cli.sh. Extra
# workstation.toml text can be given on standard input when it is not a
# terminal and not empty.
launcher_instance() {
  (($# == 1)) || ds_fail "launcher_instance: usage: launcher_instance DIR"
  local dir=$1 extra=""
  [[ -f $launcher_template ]] || ds_fail "launcher template missing: $launcher_template"
  [[ -t 0 ]] || extra=$(cat)
  mkdir -p "$dir/.dotsteward" "$dir/components/alpha"
  cp "$launcher_template" "$dir/.dotsteward/cli.sh"
  chmod 0755 "$dir/.dotsteward/cli.sh"
  cat >"$dir/workstation.toml" <<'EOF'
schema_version = 1

[identity]
username = "dotsteward-test"

[instance]
remote = "git@example.invalid:example/instance.git"

[nix]
state_version = "25.05"

[profiles]
names = ["default"]
EOF
  if [[ -n $extra ]]; then
    printf '\n%s\n' "$extra" >>"$dir/workstation.toml"
  fi
  printf '{ outputs = { self }: { }; }\n' >"$dir/flake.nix"
  launcher_write_lock "$dir" 0
  printf '{ }\n' >"$dir/components/alpha/default.nix"
  git -C "$dir" init -q
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "initial instance"
}

# launcher_write_lock DIR N: writes a valid flake.lock for a flake without
# inputs; each N gives different bytes (and therefore a different key) for
# the same lock semantics.
launcher_write_lock() {
  local dir=$1 n=$2 pad="" i
  for ((i = 0; i < n; i++)); do
    pad+=" "
  done
  printf '{\n  "nodes": {\n    "root": {}\n  },\n  "root": "root",\n  "version": 7\n}%s\n' "$pad" \
    >"$dir/flake.lock"
}

# launcher_key DIR: the cache key of DIR/flake.lock (sha256 of its bytes).
launcher_key() {
  local sum
  sum=$(sha256sum "$1/flake.lock")
  printf '%s\n' "${sum%% *}"
}

# launcher_url DIR: the git+file URL of DIR as the launcher must spell it
# (every byte outside [A-Za-z0-9/._~-] percent-encoded).
launcher_url() {
  local path=$1 out="" c i
  local LC_ALL=C
  for ((i = 0; i < ${#path}; i++)); do
    c=${path:i:1}
    case $c in
      [A-Za-z0-9/._~-]) out+=$c ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf 'git+file://%s\n' "$out"
}

# launcher_build_line DIR: the nix call line the launcher must record for
# a build of DIR, as written to the call log.
launcher_build_line() {
  _ds_call_line nix --extra-experimental-features 'nix-command flakes' --no-warn-dirty build \
    --no-link --no-update-lock-file --print-out-paths "$(launcher_url "$1")#dotsteward"
}

# launcher_use_stub_nix: the nix stub first on PATH, a nix-store shim next
# to it, and a recording bin/dotsteward in every fake build output. The fake
# CLI records "dotsteward ARG..." in the call log, prints
# "fake-cli instance=<DOTSTEWARD_INSTANCE>" and exits with
# LAUNCHER_FAKE_STATUS (default 0).
launcher_use_stub_nix() {
  ds_use_stubs nix
  local template=$DS_STUB_STATE/nix/output-template/bin
  mkdir -p "$template"
  launcher_fake_cli >"$template/dotsteward"
  chmod 0755 "$template/dotsteward"
  launcher_nix_store_shim >"$DS_TEST_ROOT/bin/nix-store"
  chmod 0755 "$DS_TEST_ROOT/bin/nix-store"
  hash -r
}

# launcher_fake_cli: prints the recording fake CLI script.
launcher_fake_cli() {
  cat <<EOF
#!$BASH
# Fake dotsteward CLI written by tests/cli/launcher/helpers.sh.
set -euo pipefail
source $(printf '%q' "$DS_REPO_ROOT/tests/lib/harness.sh")
ds_record_call dotsteward "\$@"
printf 'fake-cli instance=%s\n' "\${DOTSTEWARD_INSTANCE:-}"
exit "\${LAUNCHER_FAKE_STATUS:-0}"
EOF
}

# launcher_nix_store_shim: prints a nix-store replacement that accepts only
# "--add-root LINK --realise PATH" (in any order), records the call and
# creates LINK -> PATH like the real command.
launcher_nix_store_shim() {
  cat <<EOF
#!$BASH
# nix-store shim written by tests/cli/launcher/helpers.sh.
set -euo pipefail
source $(printf '%q' "$DS_REPO_ROOT/tests/lib/harness.sh")
ds_record_call nix-store "\$@"
root="" path="" realise=0
while ((\$#)); do
  case \$1 in
    --add-root)
      root=\$2
      shift 2
      ;;
    -r | --realise)
      realise=1
      shift
      ;;
    -*)
      printf 'nix-store shim: unsupported option: %s\n' "\$1" >&2
      exit 1
      ;;
    *)
      path=\$1
      shift
      ;;
  esac
done
if [[ -z \$root || -z \$path || \$realise != 1 || ! -e \$path ]]; then
  printf 'nix-store shim: expected --add-root LINK --realise PATH\n' >&2
  exit 1
fi
ln -sfn "\$path" "\$root"
printf '%s\n' "\$root"
EOF
}

# launcher_no_nix_path: prints a PATH value whose only directory holds links
# to the tools a launcher may need and no Nix at all.
launcher_no_nix_path() {
  local dir=$DS_TEST_ROOT/no-nix-bin tool resolved
  if [[ ! -d $dir ]]; then
    mkdir -p "$dir"
    for tool in bash sh env cat cp chmod cut date dirname basename head tail ls ln mkdir mktemp \
      mv pwd readlink realpath rm rmdir sed grep sha256sum sort stat touch tr uname wc git; do
      resolved=$(command -v "$tool" 2>/dev/null) || continue
      [[ $resolved == /* ]] || continue
      ln -s "$resolved" "$dir/$tool"
    done
  fi
  printf '%s\n' "$dir"
}

# launcher_cache_entries STATE_ROOT: the names in STATE_ROOT/cli, sorted,
# one per line (nothing when the directory is absent).
launcher_cache_entries() {
  local dir=$1/cli
  [[ -d $dir ]] || return 0
  (cd "$dir" && LC_ALL=C ls -1A)
}

# launcher_system: the Nix system string of this machine.
launcher_system() {
  local machine kernel
  machine=$(uname -m)
  kernel=$(uname -s)
  case $machine in
    arm64) machine=aarch64 ;;
  esac
  case $kernel in
    Linux) printf '%s-linux\n' "$machine" ;;
    Darwin) printf '%s-darwin\n' "$machine" ;;
    *) ds_fail "unsupported kernel: $kernel" ;;
  esac
}

# launcher_use_real_nix: the real Nix (behind recording shims for nix and
# nix-store) against an isolated store, state and configuration inside
# DS_TEST_ROOT. Sets launcher_nix_state to the isolated state directory.
launcher_use_real_nix() {
  local real_nix real_nix_store bin=$DS_TEST_ROOT/real-nix-bin name
  real_nix=$(command -v nix) || ds_fail "the dirty-tree test needs nix on PATH"
  real_nix_store=$(command -v nix-store) || ds_fail "the dirty-tree test needs nix-store on PATH"
  launcher_nix_state=$DS_TEST_ROOT/nix/state
  mkdir -p "$bin" "$DS_TEST_ROOT"/nix/{store,state,log,etc}
  for name in nix nix-store; do
    local target=$real_nix
    [[ $name == nix-store ]] && target=$real_nix_store
    cat >"$bin/$name" <<EOF
#!$BASH
# Recording shim around the real $name, written by tests/cli/launcher/helpers.sh.
source $(printf '%q' "$DS_REPO_ROOT/tests/lib/harness.sh")
ds_record_call $name "\$@"
exec $(printf '%q' "$target") "\$@"
EOF
    chmod 0755 "$bin/$name"
  done
  unset NIX_REMOTE NIX_PATH NIX_USER_CONF_FILES
  export NIX_STORE_DIR=$DS_TEST_ROOT/nix/store
  export NIX_STATE_DIR=$launcher_nix_state
  export NIX_LOG_DIR=$DS_TEST_ROOT/nix/log
  export NIX_CONF_DIR=$DS_TEST_ROOT/nix/etc
  # No sandbox (the build may already run inside one), no substituters and
  # no global registry: the fixture flake needs nothing from the network.
  # Flakes are enabled here too, so the configuration parses without
  # warnings before the launcher's own --extra-experimental-features applies.
  export NIX_CONFIG=$'experimental-features = nix-command flakes\nsandbox = false\nsubstituters =\nflake-registry =\nbuild-users-group ='
  export PATH=$bin:$PATH
  hash -r
}

# launcher_real_instance DIR: an instance whose flake builds a tiny fake CLI
# with the real Nix. The fake CLI prints "fake-cli MESSAGE BETA" where
# MESSAGE is the content of the tracked file message.txt and BETA tells
# whether the evaluation saw components/beta ("beta visible" or
# "beta hidden").
launcher_real_instance() {
  local dir=$1 system shell mkdir_path chmod_path
  system=$(launcher_system)
  shell=$BASH
  mkdir_path=$(command -v mkdir)
  chmod_path=$(command -v chmod)
  launcher_instance "$dir" </dev/null
  printf 'v1' >"$dir/message.txt"
  cat >"$dir/tools.nix" <<EOF
{
  shell = "$shell";
  mkdir = "$mkdir_path";
  chmod = "$chmod_path";
}
EOF
  cat >"$dir/flake.nix" <<EOF
{
  outputs =
    { self }:
    let
      tools = import ./tools.nix;
      message = builtins.readFile ./message.txt;
      beta = if builtins.pathExists ./components/beta then "beta visible" else "beta hidden";
    in
    {
      packages.$system.dotsteward = derivation {
        name = "dotsteward-fake";
        system = "$system";
        builder = tools.shell;
        inherit (tools) mkdir chmod;
        script = ''
          #!\${tools.shell}
          echo "fake-cli \${message} \${beta} instance=\$DOTSTEWARD_INSTANCE args=\$*"
        '';
        # The trailing builtin keeps the shell as the builder process until
        # it exits. Without it, bash -c execs the last command, and chmod
        # closes stdout and stderr before it exits: Nix reads that as the end
        # of the build, kills the process group, and on a loaded machine the
        # kill lands first, failing the build with signal 9.
        args = [
          "-c"
          ''"\$mkdir" -p "\$out/bin" && printf '%s' "\$script" >"\$out/bin/dotsteward" && "\$chmod" 0755 "\$out/bin/dotsteward" && exit 0''
        ];
      };
    };
}
EOF
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "fake CLI flake"
}
