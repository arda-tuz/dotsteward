#!/usr/bin/env bash
# The nix of the init tests: the behaviour of the nix stub's override
# (helpers.sh init_use_nix), so every call is still recorded in the call
# log. It answers the Nix commands `dotsteward init` runs, offline and
# against the isolated store of tests/nix/lib/helpers.sh:
#
#   flake lock [REF]      writes REF/flake.lock (fake-lock.nix), after
#                         copying REF (without .git) to
#                         DS_STUB_STATE/nix/staged/<n> and its path to
#                         DS_STUB_STATE/nix/staged/<n>.root (n counts from 1)
#   eval --json --no-update-lock-file REF#ATTR
#                         the JSON value of ATTR of the instance at REF,
#                         evaluated by lib.mkInstance of the framework under
#                         test (tests/nix/instance/prelude.nix) with a
#                         stand-in herdr input at the version its lock pins;
#                         the answers are cached by attribute and instance
#                         contents for the rest of the test file
#   --version             nix (Nix) 2.31.2
#
# Leading global options are dropped. DS_INIT_NIX_FAIL, a shell glob, makes
# every call whose remaining arguments (joined with spaces) match it fail
# with exit 1, except the first DS_INIT_NIX_FAIL_SKIP (default 0) of them;
# DS_INIT_NIX_HANG, a glob too, makes matching calls sleep (until they are
# killed) after writing their pid to DS_STUB_STATE/nix/hanging. Inputs:
# DS_REPO_ROOT, DS_STUB_STATE, DS_NIXPKGS, DS_HOME_MANAGER and
# DS_INIT_NIX_STORE (the isolated store).
# shellcheck disable=SC2016 # Nix expressions are single-quoted on purpose
set -euo pipefail

: "${DS_REPO_ROOT:?}" "${DS_STUB_STATE:?}" "${DS_NIXPKGS:?}" "${DS_HOME_MANAGER:?}" "${DS_INIT_NIX_STORE:?}"

fail() {
  printf 'fake nix: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case $1 in
    --extra-experimental-features | --experimental-features | --log-format)
      (($# >= 2)) || fail "$1 requires a value"
      shift 2
      ;;
    --option)
      (($# >= 3)) || fail "--option requires two values"
      shift 3
      ;;
    -L | --print-build-logs | --accept-flake-config | --no-warn-dirty | --quiet | -v | --verbose | --show-trace)
      shift
      ;;
    *) break ;;
  esac
done
key=$*

# shellcheck disable=SC2053 # DS_INIT_NIX_FAIL is a glob on purpose
if [[ -n ${DS_INIT_NIX_FAIL:-} && $key == $DS_INIT_NIX_FAIL ]]; then
  mkdir -p "$DS_STUB_STATE/nix"
  matched=$(($(cat "$DS_STUB_STATE/nix/fail-matches" 2>/dev/null || echo 0) + 1))
  printf '%s\n' "$matched" >"$DS_STUB_STATE/nix/fail-matches"
  if ((matched > ${DS_INIT_NIX_FAIL_SKIP:-0})); then
    printf 'error: injected failure of: nix %s\n' "$key" >&2
    exit 1
  fi
fi
# shellcheck disable=SC2053 # DS_INIT_NIX_HANG is a glob on purpose
if [[ -n ${DS_INIT_NIX_HANG:-} && $key == $DS_INIT_NIX_HANG ]]; then
  mkdir -p "$DS_STUB_STATE/nix"
  printf '%s\n' "$$" >"$DS_STUB_STATE/nix/hanging"
  exec sleep 600
fi

# nix-instantiate against the isolated store; its caches stay in the stub
# state.
isolated() {
  env -u NIX_REMOTE -u NIX_PATH \
    XDG_CACHE_HOME="$DS_STUB_STATE/nix/cache" \
    NIX_STORE_DIR="$DS_INIT_NIX_STORE/store" \
    NIX_STATE_DIR="$DS_INIT_NIX_STORE/state" \
    NIX_LOG_DIR="$DS_INIT_NIX_STORE/log" \
    NIX_CONF_DIR="$DS_INIT_NIX_STORE/etc" \
    NIX_LOCALSTATE_DIR="$DS_INIT_NIX_STORE/state" \
    nix-instantiate "$@"
}

# root_of REF: the directory of a local flake reference.
root_of() {
  local ref=$1
  ref=${ref#path:}
  ref=${ref#git+file://}
  ref=${ref%%\?*}
  [[ -d $ref && -f $ref/flake.nix ]] || fail "not a local flake: $1"
  (cd "$ref" && pwd -P)
}

flake_lock() {
  local ref=.
  while (($#)); do
    case $1 in
      -*) fail "unsupported flake lock option: $1" ;;
      *) ref=$1 ;;
    esac
    shift
  done
  local root lock staged count
  root=$(root_of "$ref")
  # The tests read what init composed from a copy taken here (helpers.sh
  # init_staged), also when a later step fails on purpose.
  staged=$DS_STUB_STATE/nix/staged
  mkdir -p "$staged"
  count=$(find "$staged" -mindepth 1 -maxdepth 1 -type d | wc -l)
  mkdir "$staged/$((count + 1))"
  (cd "$root" && tar --exclude=./.git -cf - .) | (cd "$staged/$((count + 1))" && tar -xf -)
  printf '%s\n' "$root" >"$staged/$((count + 1)).root"
  lock=$(isolated --eval --strict --json \
    --argstr repo "$DS_REPO_ROOT" --argstr root "$root" \
    --expr '{ repo, root }: import (/. + repo + "/tests/instance/init/fake-lock.nix") {
      frameworkLock = builtins.fromJSON (builtins.readFile (/. + repo + "/flake.lock"));
      flake = import (/. + root + "/flake.nix");
      versionsLock = builtins.fromJSON (builtins.readFile (/. + root + "/versions.lock.json"));
    }') || fail "cannot lock $root"
  jq . <<<"$lock" >"$root/flake.lock"
}

flake_eval() {
  local installable="" json=0 no_update=0
  while (($#)); do
    case $1 in
      --json) json=1 ;;
      --no-update-lock-file) no_update=1 ;;
      -*) fail "unsupported eval option: $1" ;;
      *)
        [[ -z $installable ]] || fail "more than one installable: $installable $1"
        installable=$1
        ;;
    esac
    shift
  done
  ((json && no_update)) || fail "eval without --json --no-update-lock-file: $key"
  [[ $installable == *'#'* ]] || fail "eval of a flake without an attribute: $installable"
  local root attr cache digest
  root=$(root_of "${installable%%#*}")
  attr=${installable#*#}
  [[ $attr =~ ^[A-Za-z0-9_.-]+$ ]] || fail "unsupported attribute path: $attr"
  [[ -f $root/flake.lock ]] || fail "$root has no flake.lock (run nix flake lock first)"
  cache=$DS_STUB_STATE/nix/eval-cache
  mkdir -p "$cache"
  digest=$(
    cd "$root"
    {
      printf '%s\n' "$attr"
      find . -path ./.git -prune -o -path ./.dotsteward -prune -o -type f -print | LC_ALL=C sort |
        while IFS= read -r file; do
          printf '%s %s\n' "$file" "$(sha256sum <"$file" | cut -d' ' -f1)"
        done
    } | sha256sum | cut -d' ' -f1
  )
  if [[ ! -f $cache/$digest.json ]]; then
    isolated --eval --strict --json \
      --argstr nixpkgs "$DS_NIXPKGS" --argstr homeManager "$DS_HOME_MANAGER" \
      --argstr repo "$DS_REPO_ROOT" --argstr root "$root" --argstr attr "$attr" \
      --expr '{ nixpkgs, homeManager, repo, root, attr }:
        with import (/. + repo + "/tests/nix/instance/prelude.nix") { inherit nixpkgs homeManager repo; };
        let
          rootPath = /. + root;
          lock = builtins.fromJSON (builtins.readFile (rootPath + "/versions.lock.json"));
          herdrVersion = lock.flake_inputs.herdr.version or "0.0.0";
          pkgsFor = system: import nixpkgsInput.outPath { inherit system; config = { }; overlays = [ ]; };
          herdrInput.packages = lib.genAttrs [ "x86_64-linux" "aarch64-darwin" ] (system: {
            herdr = (pkgsFor system).runCommand "herdr-${herdrVersion}" {
              pname = "herdr";
              version = herdrVersion;
            } "mkdir -p $out/bin";
          });
          inst = instance { root = rootPath; inputs.herdr = herdrInput; };
        in
        storeless (lib.getAttrFromPath (lib.splitString "." attr) inst)' \
      >"$cache/$digest.tmp" || {
      rm -f -- "$cache/$digest.tmp"
      fail "evaluation of $attr failed for $root"
    }
    mv -- "$cache/$digest.tmp" "$cache/$digest.json"
  fi
  cat -- "$cache/$digest.json"
}

case ${1:-} in
  --version) printf 'nix (Nix) 2.31.2\n' ;;
  flake)
    [[ ${2:-} == lock ]] || fail "unsupported command: nix $key"
    shift 2
    flake_lock "$@"
    ;;
  eval)
    shift
    flake_eval "$@"
    ;;
  *) fail "unsupported command: nix $key" ;;
esac
