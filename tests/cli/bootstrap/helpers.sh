# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # literal $ and ${...} text is single-quoted on purpose
# shellcheck disable=SC2034 # the bs_* variables are read by the test files
# Helpers for the preflight, stage-0 and bootstrap tests (tests/cli/bootstrap).
# Not a test file.
#
# Sourcing this file builds, inside DS_TEST_ROOT:
#   bs_fw        a copy of the framework under test (cli/, schema/, tools/,
#                template/ and VERSION; an empty modules/components, so the
#                catalog is empty)
#   bs_inst      a synthetic instance, a git repository with everything
#                committed: workstation.toml (profiles "workstation", adopt
#                mode, default and check, and "fresh", fresh mode and the
#                bootstrap profile; remote bs_remote_url), flake.nix,
#                flake.lock, versions.lock.json (the Nix pin of the fake
#                installer, in the canonical lock layout), the manifest
#                mirror .dotsteward/manifest.x86_64-linux.json (no
#                components, no hooks), the stage-0 mirrors
#                .dotsteward/stage0.linux.env and stage0.darwin.env (see
#                stage0_env_write), bootstrap.sh (the framework's
#                template/bootstrap.sh) and .dotsteward/cli.sh, a fake
#                launcher that records "cli.sh ARG..."
#   bs_remote    a bare repository that fakessh serves for bs_remote_url
#                (GIT_SSH_COMMAND is fakessh for every test: no test reaches
#                the network)
#   bs_installer the fake Nix installer the curl stub serves at
#                bs_installer_url: run as `sh installer ARG...`, it records
#                "nix-installer ARG..." and installs $HOME/.nix-profile/bin/nix,
#                which prints "nix (Nix) <version>" with the content of
#                DS_TEST_ROOT/installed-nix-version (default 2.35.2)
#   bs_bash      the shell that runs stage-0: DS_BASH32 when the caller
#                provides it (the Nix check builds GNU bash 3.2.57, the
#                macOS /bin/bash), else $BASH
# __ETC_PROFILE_NIX_SOURCED=1 is exported, so the host's Nix daemon profile
# never puts a real nix on PATH.
#
#   stage0_env_write PLATFORM          (re)writes .dotsteward/stage0.PLATFORM.env
#                                      with the defaults below and commits
#   stage0_env_set PLATFORM LINE...    appends assignments (later ones win)
#                                      and commits
#   stage0_path                        a PATH for stage-0: the stubs
#                                      directory, then links to the basic
#                                      tools; no nix, no jq, no python3
#   cli_path                           the basic tools of stage0_path plus
#                                      jq and python3 (the CLI's toolchain);
#                                      no stubs, no nix
#   run_stage0 [ENV...] -- ARG...      bash bootstrap.sh ARG... of the
#                                      instance with bs_bash under env(1)
#                                      with ENV (options such as -u NAME
#                                      first, then NAME=VALUE) and
#                                      PATH=stage0_path; standard input is
#                                      empty
#   run_preflight ARG...               dotsteward --instance <instance>
#                                      preflight ARG... (normal PATH)
#   run_bootstrap ARG...               dotsteward --instance <instance>
#                                      bootstrap ARG...
#   expected_preflight_json PROFILE ROUTE FAST OS_ID OS_VERSION ARCH DESKTOP
#                           NIX_VERSION|null FREE_KIB REMOTE [NAME=BOOL...]
#                                      the document today's jq program
#                                      printed (jq --indent 2), detectors
#                                      appended to platform in order
#   preflight_free_kib JSON            the free_kib of a printed document
#   backup_dirs                        the backup directories of the state
#                                      root, one per line
#   instance_commit MESSAGE            commits every change of the instance

source "$DS_REPO_ROOT/tests/lib/bare-remote.sh"
source "$DS_REPO_ROOT/tests/lib/fakessh.sh"

bs_fw=$DS_TEST_ROOT/framework
bs_inst=$DS_TEST_ROOT/instance
bs_remote=$DS_TEST_ROOT/remote.git
bs_remote_url=git@github.com:example-org/workstation.git
bs_installer=$DS_TEST_ROOT/nix-installer.sh
bs_installer_url=https://releases.example.invalid/nix/nix-2.35.2/install
bs_bash=${DS_BASH32:-$BASH}
bs_arch=$(uname -m)
export __ETC_PROFILE_NIX_SOURCED=1

mkdir -p "$bs_fw/modules/components" "$bs_inst/.dotsteward" "$bs_inst/agent/skills"
cp -R "$DS_REPO_ROOT/cli" "$DS_REPO_ROOT/schema" "$DS_REPO_ROOT/tools" "$DS_REPO_ROOT/VERSION" "$bs_fw/"
if [[ -d $DS_REPO_ROOT/template ]]; then
  cp -R "$DS_REPO_ROOT/template" "$bs_fw/"
fi

instance_commit() {
  git -C "$bs_inst" add -A
  git -C "$bs_inst" commit -q --allow-empty -m "$1"
}

git -C "$bs_inst" init -q

cat >"$bs_inst/workstation.toml" <<EOF
schema_version = 1

[identity]
username = "dotsteward-test"

[instance]
name = "workstation"
remote = "$bs_remote_url"

[nix]
systems = ["x86_64-linux", "aarch64-darwin"]
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
EOF
printf '{ outputs = { self }: { }; }\n' >"$bs_inst/flake.nix"
printf '{\n  "nodes": { "root": {} },\n  "root": "root",\n  "version": 7\n}\n' >"$bs_inst/flake.lock"
jq -n '{ schema_version: "1.0", expected_skill_count: 0, skills: [] }' >"$bs_inst/agent/skills.lock.json"
for bs_system in x86_64-linux aarch64-darwin; do
  jq -n --arg system "$bs_system" --arg platform "${bs_system#*-}" '{
    schema_version: 1,
    system: $system,
    platform: $platform,
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
    backup_paths: ["~/.config/nix/nix.conf", "~/.agents/skills"],
    snapshots: [],
    prerequisites: { apt: [] },
    preflight_detectors: {},
    skill_layout: { legacy_roots: [], link_roots: {}, excluded_subtrees: [] },
    skills: { hm_root: ".agents/skills", framework: [], home_managed: [], framework_manifest: null },
    login_shell: "$HOME/.nix-profile/bin/zsh"
  }' >"$bs_inst/.dotsteward/manifest.$bs_system.json"
done
unset bs_system

# The fake Nix installer and the Nix it installs.
cat >"$bs_installer" <<EOF
# Fake Nix installer of the bootstrap tests (run with sh).
printf 'nix-installer %s\n' "\$*" >>"\$DS_CALL_LOG"
mkdir -p "\$HOME/.nix-profile/bin"
cat >"\$HOME/.nix-profile/bin/nix" <<'NIX'
#!$BASH
version=2.35.2
if [ -f "\$DS_TEST_ROOT/installed-nix-version" ]; then
  version=\$(cat "\$DS_TEST_ROOT/installed-nix-version")
fi
case \${1:-} in
  --version) printf 'nix (Nix) %s\n' "\$version" ;;
  *) printf 'fake nix: unsupported: %s\n' "\$*" >&2; exit 1 ;;
esac
NIX
chmod 0755 "\$HOME/.nix-profile/bin/nix"
EOF
bs_installer_size=$(wc -c <"$bs_installer")
bs_installer_size=${bs_installer_size//[[:space:]]/}
bs_installer_sha256=$(sha256sum <"$bs_installer")
bs_installer_sha256=${bs_installer_sha256%% *}

cat >"$bs_inst/versions.lock.json" <<EOF
{
  "schema_version": "1.0",
  "policy": {
    "official_sources_only": true,
    "persistent_agentic_updates": false
  },
  "nix": {
    "version": "2.35.2",
    "installer_url": "$bs_installer_url",
    "installer_size": $bs_installer_size,
    "installer_sha256": "$bs_installer_sha256"
  },
  "flake_inputs": {
    "nixpkgs": {
      "reference": "github:NixOS/nixpkgs/0000000000000000000000000000000000000000",
      "version": "1"
    }
  }
}
EOF

stage0_env_write() {
  local platform=$1 file=$bs_inst/.dotsteward/stage0.$1.env system
  case $platform in
    linux) system=x86_64-linux ;;
    darwin) system=aarch64-darwin ;;
    *) ds_fail "stage0_env_write: unknown platform $platform" ;;
  esac
  {
    printf '# Generated by dotsteward from workstation.toml, the components and the lock\n'
    printf '# (%s). Test fixture of tests/cli/bootstrap.\n' "$system"
    printf 'DS_STAGE0_SCHEMA_VERSION=1\n'
    printf 'DS_STAGE0_SYSTEM=%s\n' "$system"
    printf 'DS_STAGE0_PLATFORM=%s\n' "$platform"
    printf 'DS_STAGE0_INSTANCE_REMOTE=%s\n' "$bs_remote_url"
    printf "DS_STAGE0_STATE_ROOT='\${XDG_STATE_HOME:-~/.local/state}/dotsteward'\n"
    printf 'DS_STAGE0_LEGACY_ENV=false\n'
    printf 'DS_STAGE0_HOST_INPUT=instance\n'
    printf 'DS_STAGE0_VERSIONS_LOCK=versions.lock.json\n'
    printf 'DS_STAGE0_PROFILES=(workstation fresh)\n'
    printf "DS_STAGE0_PROFILE_MODES=('workstation=adopt' 'fresh=fresh')\n"
    printf 'DS_STAGE0_DEFAULT_PROFILE=workstation\n'
    printf 'DS_STAGE0_CHECK_PROFILE=workstation\n'
    printf 'DS_STAGE0_BOOTSTRAP_PROFILE=fresh\n'
    if [[ $platform == linux ]]; then
      printf 'DS_STAGE0_FAST_PATH_OS_ID=ubuntu\n'
      printf 'DS_STAGE0_FAST_PATH_OS_VERSION=24.04\n'
      printf 'DS_STAGE0_FAST_PATH_ARCHITECTURE=%s\n' "$bs_arch"
      printf "DS_STAGE0_FAST_PATH_DESKTOP_CONTAINS=''\n"
      printf 'DS_STAGE0_FAST_PATH_DETECTORS=()\n'
    else
      printf 'DS_STAGE0_FAST_PATH_MIN_VERSION=14\n'
      printf 'DS_STAGE0_FAST_PATH_ARCHITECTURE=%s\n' "$bs_arch"
    fi
    printf 'DS_STAGE0_DETECTORS=()\n'
    printf "DS_STAGE0_BACKUP_PATHS=('~/.config/nix/nix.conf' '~/.agents/skills')\n"
    printf 'DS_STAGE0_SNAPSHOTS=()\n'
    printf 'DS_STAGE0_PREREQUISITES_APT=()\n'
    printf 'DS_STAGE0_NIX_VERSION_AT=nix.version\n'
    printf 'DS_STAGE0_NIX_INSTALLER_URL_AT=nix.installer_url\n'
    printf 'DS_STAGE0_NIX_INSTALLER_SIZE_AT=nix.installer_size\n'
    printf 'DS_STAGE0_NIX_INSTALLER_SHA256_AT=nix.installer_sha256\n'
    printf 'DS_STAGE0_NIX_VERSION=2.35.2\n'
    printf 'DS_STAGE0_NIX_INSTALLER_URL=%s\n' "$bs_installer_url"
    printf 'DS_STAGE0_NIX_INSTALLER_SIZE=%s\n' "$bs_installer_size"
    printf 'DS_STAGE0_NIX_INSTALLER_SHA256=%s\n' "$bs_installer_sha256"
  } >"$file"
  instance_commit "stage-0 mirror $platform"
}

stage0_env_set() {
  local platform=$1 line
  shift
  for line in "$@"; do
    printf '%s\n' "$line" >>"$bs_inst/.dotsteward/stage0.$platform.env"
  done
  instance_commit "stage-0 mirror $platform change"
}

stage0_env_write linux
stage0_env_write darwin

if [[ -f $bs_fw/template/bootstrap.sh ]]; then
  cp "$bs_fw/template/bootstrap.sh" "$bs_inst/bootstrap.sh"
  chmod 0755 "$bs_inst/bootstrap.sh"
fi
cat >"$bs_inst/.dotsteward/cli.sh" <<EOF
#!$BASH
# Fake instance launcher of the bootstrap tests.
set -euo pipefail
source $(printf %q "$DS_REPO_ROOT/tests/lib/harness.sh")
ds_record_call cli.sh "\$@"
EOF
chmod 0755 "$bs_inst/.dotsteward/cli.sh"
instance_commit "instance"

ds_git_repo "$DS_TEST_ROOT/remote-source"
ds_bare_remote "$bs_remote" "$DS_TEST_ROOT/remote-source"
ds_fakessh_enable
ds_fakessh_map "$bs_remote_url" "$bs_remote"
ds_curl_serve "$bs_installer_url" "$bs_installer"

# Every tool stage-0, the stubs and the fake programs need, and nothing
# that the pre-Nix stage-0 must not rely on.
_bs_link_tools() {
  local dir=$1 tool resolved
  shift
  mkdir -p "$dir"
  for tool in "$@"; do
    [[ -e $dir/$tool ]] && continue
    resolved=$(type -P "$tool" 2>/dev/null) || continue
    [[ $resolved == /* ]] || continue
    ln -s "$resolved" "$dir/$tool"
  done
}

stage0_path() {
  local dir=$DS_TEST_ROOT/stage0-tools
  if [[ ! -d $dir ]]; then
    _bs_link_tools "$dir" awk basename bash cat chmod cmp cp cut date df diff dirname env file find \
      gawk grep head id ln ls mkdir mktemp mv od readlink realpath rm rmdir sed sh sha256sum sleep \
      sort stat tail tee timeout touch tr uname wc xargs git git-upload-pack git-receive-pack
  fi
  printf '%s:%s\n' "$DS_TEST_ROOT/bin" "$dir"
}

cli_path() {
  local dir=$DS_TEST_ROOT/cli-tools python
  stage0_path >/dev/null
  if [[ ! -d $dir ]]; then
    _bs_link_tools "$dir" jq flock
    # The interpreter itself: a version-manager shim on PATH would look for
    # its real python3 on the restricted PATH.
    python=$(python3 -c 'import sys; print(sys.executable)') || ds_fail "cli_path: no python3"
    ln -s "$python" "$dir/python3"
  fi
  printf '%s:%s\n' "$DS_TEST_ROOT/stage0-tools" "$dir"
}

# The stubs directory exists from the start, so PATH values that name it
# stay valid when a test adds stubs later.
mkdir -p "$DS_TEST_ROOT/bin"

run_stage0() {
  local assignments=()
  while (($#)) && [[ $1 != -- ]]; do
    assignments+=("$1")
    shift
  done
  [[ ${1:-} == -- ]] && shift
  # The inner env applies the caller's options and assignments (a PATH
  # among them wins).
  env PATH="$(stage0_path)" env "${assignments[@]}" "$bs_bash" "$bs_inst/bootstrap.sh" "$@" </dev/null
}

run_preflight() {
  "$bs_fw/cli/dotsteward" --instance "$bs_inst" preflight "$@" </dev/null
}

run_bootstrap() {
  "$bs_fw/cli/dotsteward" --instance "$bs_inst" bootstrap "$@" </dev/null
}

expected_preflight_json() {
  local profile=$1 route=$2 fast=$3 os_id=$4 os_version=$5 arch=$6 desktop=$7 nix=$8 free=$9
  local remote=${10} detectors='{}' pair
  shift 10
  for pair in "$@"; do
    detectors=$(jq -c --arg name "${pair%%=*}" --argjson value "${pair#*=}" '. + { ($name): $value }' <<<"$detectors")
  done
  jq -n --indent 2 \
    --arg schema_version '1.0' \
    --arg profile "$profile" \
    --arg os_id "$os_id" \
    --arg os_version "$os_version" \
    --arg architecture "$arch" \
    --arg desktop "$desktop" \
    --arg route "$route" \
    --arg nix_version "$nix" \
    --argjson detectors "$detectors" \
    --argjson fast_path "$fast" \
    --argjson remote_accessible "$remote" \
    --argjson free_kib "$free" \
    '{
      schema_version: $schema_version,
      profile: $profile,
      route: $route,
      fast_path: $fast_path,
      platform: ({
        os_id: $os_id,
        os_version: $os_version,
        architecture: $architecture,
        desktop: $desktop
      } + $detectors),
      nix_version: (if $nix_version == "null" then null else $nix_version end),
      free_kib: $free_kib,
      github_ssh_remote_accessible: $remote_accessible,
      writes_performed: false
    }'
}

preflight_free_kib() {
  jq -er '.free_kib | select(type == "number" and . >= 0)' <<<"$1" ||
    ds_fail "no free_kib number in [$1]"
}

backup_dirs() {
  local root=$DOTSTEWARD_STATE_ROOT/backups
  [[ -d $root ]] || return 0
  find "$root" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort
}
