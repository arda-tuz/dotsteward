# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh and config_load
# shellcheck disable=SC2016 # bash -c scripts and literal $ in TOML values
# cli/lib/config.sh: config_load turns the resolved configuration into DS_*
# shell variables (scalars, indexed and associative arrays), expands ~/ and
# ${VAR:-default} paths with the runtime environment, applies the
# environment overrides of SPEC 6.1 and exports the instance and state root.
# shellcheck source=tests/cli/config/helpers.sh
source "$DS_REPO_ROOT/tests/cli/config/helpers.sh"

fw=$DS_TEST_ROOT/framework
make_framework "$fw"
instance=$DS_TEST_ROOT/instances/workstation
make_instance "$instance" "$nix_valid_fixtures/full.toml"
mkdir -p "$instance/agent/overlays"
printf 'overlay\n' >"$instance/agent/overlays/dotsteward-update.md"
unset DOTSTEWARD_STATE_ROOT

export DOTSTEWARD_PLATFORM=linux
load_config "$fw" "$instance"

# Scalars.
assert_eq "$instance/workstation.toml" "$DS_CONFIG_FILE"
assert_eq "$instance" "$DS_INSTANCE_ROOT"
assert_eq linux "$DS_RUNTIME_PLATFORM"
assert_eq alice "$DS_IDENTITY_USERNAME"
assert_eq /home/alice "$DS_IDENTITY_HOME"
assert_eq /Users/alice "$DS_IDENTITY_DARWIN_HOME"
assert_eq workstation "$DS_INSTANCE_NAME"
assert_eq git@github.com:alice/workstation.git "$DS_INSTANCE_REMOTE"
assert_eq trunk "$DS_INSTANCE_BRANCH"
assert_eq "$HOME/src/workstation" "$DS_INSTANCE_CHECKOUT"
assert_eq "$HOME/.local/state/workstation" "$DS_STATE_ROOT"
assert_eq x86_64-linux "$DS_NIX_PRIMARY_SYSTEM"
assert_eq true "$DS_NIX_ALLOW_UNFREE"
assert_eq 26.05 "$DS_NIX_STATE_VERSION"
assert_eq workstation "$DS_PROFILES_DEFAULT"
assert_eq workstation "$DS_PROFILES_CHECK"
assert_eq fresh "$DS_PROFILES_BOOTSTRAP"
assert_eq ubuntu "$DS_PLATFORM_LINUX_OS_ID"
assert_eq 24.04 "$DS_PLATFORM_LINUX_OS_VERSION"
assert_eq x86_64 "$DS_PLATFORM_LINUX_ARCHITECTURE"
assert_eq example "$DS_PLATFORM_LINUX_DESKTOP_CONTAINS"
assert_eq 15 "$DS_PLATFORM_DARWIN_MIN_VERSION"
assert_eq arm64 "$DS_PLATFORM_DARWIN_ARCHITECTURE"
assert_eq 4 "$DS_GATE_NIX_MAX_JOBS"
assert_eq 8 "$DS_GATE_NIX_CORES"
assert_eq 10 "$DS_GATE_MIN_FREE_GIB"
assert_eq 20 "$DS_GATE_PREPARE_WARN_FREE_GIB"
assert_eq https://cache.example.invalid "$DS_GATE_CACHE_URL"
assert_eq "chore: refresh pins" "$DS_COMMIT_UPDATE_SUBJECT"
assert_eq "chore: sync settings" "$DS_COMMIT_SETTINGS_SUBJECT"
assert_eq "chore: dotsteward {version}" "$DS_COMMIT_UPGRADE_SUBJECT"
assert_eq settings-buffer "$DS_SETTINGS_BUFFER_DIR"
assert_eq upstream/trunk "$DS_SETTINGS_PUBLISHED_REF"
assert_eq agent/skills.lock.json "$DS_SKILLS_LOCK"
assert_eq agent/vendor "$DS_SKILLS_VENDOR_DIR"
assert_eq .codex/skills "$DS_SKILLS_HM_ROOT"
assert_eq locks/versions.lock.json "$DS_PINS_VERSIONS_LOCK"
assert_eq arm64 "$DS_PINS_APT_ARCH"
assert_eq "$HOME/.config/workstation/denylist.txt" "$DS_PRIVACY_DENYLIST"
assert_eq '[{"files":["profiles/example-app/state.ini"],"message":"example profile contains recent items","pattern":"\\[recent items\\]"}]' \
  "$DS_PRIVACY_FILE_RULES_JSON"
assert_eq agent/AGENTS.md "$DS_AGENT_RULES_SOURCE"
assert_eq owner "$DS_UPSTREAM_CONTRIBUTE"
assert_eq alice/dotsteward "$DS_UPSTREAM_FORK"
assert_eq true "$DS_UPSTREAM_PR_TO_UPSTREAM"
assert_eq "$HOME/src/dotsteward" "$DS_UPSTREAM_LOCAL_CLONE"
assert_eq true "$DS_COMPAT_LEGACY_ENV"
assert_eq true "$DS_COMPAT_LEGACY_BACKUP_LAYOUT"
assert_eq same-as-instance-checkout "$DS_COMPAT_REPO_OWNED_REVISION"
assert_eq workstation "$DS_COMPAT_HOST_INPUT"

# Indexed arrays.
assert_eq "x86_64-linux aarch64-darwin" "${DS_NIX_SYSTEMS[*]}"
assert_eq "workstation fresh" "${DS_PROFILES_NAMES[*]}"
assert_eq example_detector "${DS_PLATFORM_LINUX_DETECTORS[*]}"
assert_eq tests/static.sh "${DS_GATE_STATIC[*]}"
assert_eq 2 "${#DS_GATE_UPDATE_ALLOWLIST[@]}"
assert_eq 'flake\.lock' "${DS_GATE_UPDATE_ALLOWLIST[0]}"
assert_eq 'components/[^/]+/default\.nix' "${DS_GATE_UPDATE_ALLOWLIST[1]}"
assert_eq "shell example-term herdr claude-code codex opencode-pi vscode example-app" "${DS_COMPONENTS_ORDER[*]}"
assert_eq "shell example-term herdr claude-code codex vscode example-app" "${DS_COMPONENTS_ENABLED[*]}"
assert_eq 5 "${#DS_SKILLS_INSTALLER[@]}"
assert_eq "{home}/.local/bin/skill-installer add {source} --skill {name}" "${DS_SKILLS_INSTALLER[*]}"
assert_eq "dotsteward example-input" "${DS_PINS_EXCLUDED_FLAKE_INPUTS[*]}"
assert_eq "*private-notes*" "${DS_PRIVACY_FORBIDDEN_PATHS[*]}"

# Associative arrays.
assert_eq adopt "${DS_PROFILE_MODE[workstation]}"
assert_eq fresh "${DS_PROFILE_MODE[fresh]}"
assert_eq 2 "${#DS_PROFILE_MODE[@]}"
assert_eq 8 "${#DS_COMPONENT_ENABLE[@]}"
assert_eq true "${DS_COMPONENT_ENABLE[shell]}"
assert_eq false "${DS_COMPONENT_ENABLE[opencode-pi]}"
assert_eq catalog "${DS_COMPONENT_SOURCE[vscode]}"
assert_eq instance "${DS_COMPONENT_SOURCE[example-term]}"
assert_eq instance "${DS_COMPONENT_SOURCE[example-app]}"
assert_eq deb "${DS_COMPONENT_METHOD[claude-code]}"
assert_eq deb "${DS_COMPONENT_METHOD[vscode]}"
assert_eq official-binary "${DS_COMPONENT_METHOD[example-term]}"
assert_eq "" "${DS_COMPONENT_METHOD[shell]}"
assert_eq workstation "${DS_COMPONENT_PROFILES[herdr]}"
assert_eq "" "${DS_COMPONENT_PROFILES[shell]}"
# The given overlay, plus agent/overlays/<skill>.md where it exists.
assert_eq agent/overlays/maintain.md "${DS_SKILLS_OVERLAYS[dotsteward-maintain]}"
assert_eq agent/overlays/dotsteward-update.md "${DS_SKILLS_OVERLAYS[dotsteward-update]}"
assert_eq 2 "${#DS_SKILLS_OVERLAYS[@]}"
assert_eq example-tool "${DS_PINS_NIXPKGS_VERSIONS[example-tool]}"
assert_eq example-fonts.mono "${DS_PINS_NIXPKGS_VERSIONS[example-font]}"
assert_eq e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 "${DS_PROTECTED[home/AGENTS.md]}"
assert_eq fresh "${DS_COMPAT_CHECK_ALIASES[fresh-home]}"

# Kinds: arrays are arrays, scalars are exported to child processes.
[[ $(declare -p DS_NIX_SYSTEMS) == "declare -a "* ]] || ds_fail "DS_NIX_SYSTEMS is not an indexed array"
[[ $(declare -p DS_COMPONENT_ENABLE) == "declare -A "* ]] || ds_fail "DS_COMPONENT_ENABLE is not associative"
assert_eq "$HOME/.local/state/workstation|$instance|trunk" \
  "$(bash -c 'printf "%s|%s|%s" "$DS_STATE_ROOT" "$DOTSTEWARD_INSTANCE" "$DS_INSTANCE_BRANCH"')"
# lib.sh uses the configured state root; it is not exported, so a child
# that loads another instance does not take it as an override.
assert_eq "$HOME/.local/state/workstation" "$(state_root)"
assert_eq unset "$(bash -c 'printf "%s" "${DOTSTEWARD_STATE_ROOT-unset}"')"

# DS_CONFIG_JSON is the resolved configuration of the Nix parity layer (no
# expansion), with the directory name as the instance-name fallback.
expected=$(config_py --file "$instance/workstation.toml" --catalog "$(config_catalog)" \
  --instance-name workstation resolve)
assert_eq "$(jq -S . <<<"$expected")" "$(jq -S . <<<"$DS_CONFIG_JSON")"

# Helpers.
assert_eq "trunk" "$(config_query .instance.branch)"
assert_eq '["workstation","fresh"]' "$(config_query -c .profiles.names)"
assert_exit 1 config_query '.instance |||'
assert_contains "$DS_STDERR" "[dotsteward] ERROR: invalid configuration query: .instance |||"
assert_eq "$instance/settings-buffer" "$(config_instance_path "$DS_SETTINGS_BUFFER_DIR")"
assert_eq adopt "$(config_profile_mode workstation)"
assert_exit 1 config_profile_mode nope
assert_contains "$DS_STDERR" "[dotsteward] ERROR: unknown profile: nope"
config_component_active herdr workstation || ds_fail "herdr is active in workstation"
! config_component_active herdr fresh || ds_fail "herdr is scoped to workstation"
config_component_active shell fresh || ds_fail "shell has no profile scope"
! config_component_active opencode-pi workstation || ds_fail "opencode-pi is disabled"
assert_exit 1 config_component_active nope workstation
assert_contains "$DS_STDERR" "[dotsteward] ERROR: unknown component: nope"

# The runtime platform picks method_by_platform.
DOTSTEWARD_PLATFORM=darwin load_config "$fw" "$instance"
assert_eq darwin "$DS_RUNTIME_PLATFORM"
assert_eq app-archive "${DS_COMPONENT_METHOD[vscode]}"
assert_eq external "${DS_COMPONENT_METHOD[codex]}"
assert_exit 1 env DOTSTEWARD_PLATFORM=windows bash -c 'source "$1/cli/lib/lib.sh"; source "$1/cli/lib/config.sh"; config_load "$2"' \
  _ "$fw" "$instance"
assert_contains "$DS_STDERR" "DOTSTEWARD_PLATFORM: expected linux or darwin, got windows"

# Defaults and expansion on the minimal instance: the state root default
# follows XDG_STATE_HOME, the checkout follows the directory name.
minimal=$DS_TEST_ROOT/instances/minimal-ws
make_instance "$minimal"
load_config "$fw" "$minimal"
assert_eq minimal-ws "$DS_INSTANCE_NAME"
assert_eq "$HOME/minimal-ws" "$DS_INSTANCE_CHECKOUT"
assert_eq "$HOME/.local/state/dotsteward" "$DS_STATE_ROOT"
assert_eq "$HOME/.local/share/dotsteward/framework" "$DS_UPSTREAM_LOCAL_CLONE"
assert_eq "" "$DS_PRIVACY_DENYLIST"
assert_eq "" "$DS_UPSTREAM_FORK"
assert_eq 0 "${#DS_SKILLS_INSTALLER[@]}"
assert_eq 0 "${#DS_SKILLS_OVERLAYS[@]}"
assert_eq 0 "${#DS_COMPONENTS_ENABLED[@]}"
assert_eq "shell herdr claude-code codex opencode-pi vscode" "${DS_COMPONENTS_ORDER[*]}"
assert_eq "[]" "$DS_PRIVACY_FILE_RULES_JSON"
XDG_STATE_HOME=$DS_TEST_ROOT/xdg-state XDG_DATA_HOME=$DS_TEST_ROOT/xdg-data load_config "$fw" "$minimal"
assert_eq "$DS_TEST_ROOT/xdg-state/dotsteward" "$DS_STATE_ROOT"
assert_eq "$DS_TEST_ROOT/xdg-data/dotsteward/framework" "$DS_UPSTREAM_LOCAL_CLONE"
# An empty variable counts as unset, like ${VAR:-default}.
XDG_STATE_HOME='' load_config "$fw" "$minimal"
assert_eq "$HOME/.local/state/dotsteward" "$DS_STATE_ROOT"

# Environment overrides (SPEC 6.1): DOTSTEWARD_* always, DOTFILES_* only as
# fallbacks when compat.legacy_env is true; empty values count as unset.
DOTSTEWARD_STATE_ROOT=$DS_TEST_ROOT/env-state DOTSTEWARD_NIX_MAX_JOBS=3 DOTSTEWARD_NIX_CORES=0 \
  DOTSTEWARD_MIN_FREE_GB=1 DOTSTEWARD_CACHE_URL=http://cache.example.invalid load_config "$fw" "$minimal"
assert_eq "$DS_TEST_ROOT/env-state" "$DS_STATE_ROOT"
assert_eq "3 0 1 http://cache.example.invalid" \
  "$DS_GATE_NIX_MAX_JOBS $DS_GATE_NIX_CORES $DS_GATE_MIN_FREE_GIB $DS_GATE_CACHE_URL"
DOTFILES_STATE_ROOT=$DS_TEST_ROOT/legacy-state DOTFILES_NIX_MAX_JOBS=7 load_config "$fw" "$minimal"
assert_eq "$HOME/.local/state/dotsteward" "$DS_STATE_ROOT" "legacy names ignored without compat.legacy_env"
assert_eq 5 "$DS_GATE_NIX_MAX_JOBS"
DOTFILES_STATE_ROOT=$DS_TEST_ROOT/legacy-state DOTFILES_NIX_MAX_JOBS=7 DOTFILES_NIX_CORES=5 \
  DOTFILES_MIN_FREE_GB=9 DOTFILES_CACHE_URL=https://legacy.example.invalid load_config "$fw" "$instance"
assert_eq "$DS_TEST_ROOT/legacy-state" "$DS_STATE_ROOT"
assert_eq "7 5 9 https://legacy.example.invalid" \
  "$DS_GATE_NIX_MAX_JOBS $DS_GATE_NIX_CORES $DS_GATE_MIN_FREE_GIB $DS_GATE_CACHE_URL"
DOTSTEWARD_STATE_ROOT=$DS_TEST_ROOT/new-state DOTFILES_STATE_ROOT=$DS_TEST_ROOT/legacy-state \
  DOTSTEWARD_NIX_MAX_JOBS=1 DOTFILES_NIX_MAX_JOBS=7 load_config "$fw" "$instance"
assert_eq "$DS_TEST_ROOT/new-state 1" "$DS_STATE_ROOT $DS_GATE_NIX_MAX_JOBS" "DOTSTEWARD_* wins"
DOTSTEWARD_STATE_ROOT='' DOTFILES_STATE_ROOT='' DOTSTEWARD_NIX_MAX_JOBS='' load_config "$fw" "$instance"
assert_eq "$HOME/.local/state/workstation 4" "$DS_STATE_ROOT $DS_GATE_NIX_MAX_JOBS"

# Invalid overrides are refused with every problem, before anything is set.
run_load() {
  env "$@" bash -c 'source "$1/cli/lib/lib.sh"; source "$1/cli/lib/config.sh"; config_load "$2"' _ "$fw" "$minimal"
}
assert_exit 1 run_load DOTSTEWARD_NIX_MAX_JOBS=0 DOTSTEWARD_NIX_CORES=x DOTSTEWARD_MIN_FREE_GB=-1 \
  DOTSTEWARD_CACHE_URL=ftp://x DOTSTEWARD_STATE_ROOT=relative/state
assert_eq "[dotsteward] ERROR: DOTSTEWARD_STATE_ROOT: expected an absolute path, got \"relative/state\"
[dotsteward] ERROR: DOTSTEWARD_NIX_MAX_JOBS: expected an integer >= 1, got \"0\"
[dotsteward] ERROR: DOTSTEWARD_NIX_CORES: expected an integer >= 0, got \"x\"
[dotsteward] ERROR: DOTSTEWARD_MIN_FREE_GB: expected an integer >= 0, got \"-1\"
[dotsteward] ERROR: DOTSTEWARD_CACHE_URL: \"ftp://x\" does not match \"^https?://.+\$\"" "$DS_STDERR"

# Paths that expand to relative paths are refused; a relative denylist is
# relative to the instance root.
relative=$DS_TEST_ROOT/instances/relative
make_instance "$relative"
printf '[state]\nroot = "state"\n[privacy]\ndenylist = "private/deny.txt"\n' >>"$relative/workstation.toml"
assert_exit 1 env bash -c 'source "$1/cli/lib/lib.sh"; source "$1/cli/lib/config.sh"; config_load "$2"' _ "$fw" "$relative"
assert_eq '[dotsteward] ERROR: workstation.toml: state.root: expands to a relative path: "state"' "$DS_STDERR"
sed -i 's|^root = "state"|root = "/var/tmp/ws-state"|' "$relative/workstation.toml"
load_config "$fw" "$relative"
assert_eq /var/tmp/ws-state "$DS_STATE_ROOT"
assert_eq "$relative/private/deny.txt" "$DS_PRIVACY_DENYLIST"

# Values with shell metacharacters survive the round trip unchanged.
quoted=$DS_TEST_ROOT/instances/quoted
make_instance "$quoted"
cat >>"$quoted/workstation.toml" <<'EOF'
[commit]
update_subject = "it's a \"$HOME\" `date` $(id) \\ \\n tab\tend\nsecond line"
[gate]
update_allowlist = ["a b", "'quoted'", "$(x)", "back\\slash", "new\nline"]
[protected]
"odd ]key[ with spaces/file" = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
EOF
load_config "$fw" "$quoted"
assert_eq "it's a \"\$HOME\" \`date\` \$(id) \\ \\n tab"$'\t'"end"$'\n'"second line" "$DS_COMMIT_UPDATE_SUBJECT"
assert_eq 5 "${#DS_GATE_UPDATE_ALLOWLIST[@]}"
assert_eq "a b|'quoted'|\$(x)|back\\slash|new"$'\n'"line" "$(IFS='|'; printf '%s' "${DS_GATE_UPDATE_ALLOWLIST[*]}")"
key='odd ]key[ with spaces/file'
assert_eq e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 "${DS_PROTECTED[$key]}"
[[ ! -e $DS_TEST_ROOT/work/x ]] || ds_fail "a value was executed"

# The exporter prints one declaration per line (control characters use
# $'...' quoting), nothing else.
exported=$(cd "$quoted" && DOTSTEWARD_PLATFORM=linux config_py --catalog "$(config_catalog)" export)
while IFS= read -r line; do
  [[ $line == "declare -g"* ]] || ds_fail "unexpected exporter line: $line"
done <<<"$exported"
assert_contains "$exported" "declare -gx DS_COMMIT_UPDATE_SUBJECT=\$'it\\'s a"
