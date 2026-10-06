# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # jq programs and shell snippets are single-quoted on purpose
# Helpers for the agents installer tests (tests/agents). Not a test file.
#
# Sourcing this file builds, inside DS_TEST_ROOT:
#   agents_fw        a copy of the framework under test (cli/, schema/,
#                    VERSION and an empty modules/components, so the catalog
#                    is empty)
#   agents_inst      a synthetic instance: workstation.toml with the profiles
#                    "workstation" (adopt mode, the check profile) and
#                    "fresh" (fresh mode), an empty versions.lock.json, an
#                    empty skills lock agent/skills.lock.json and the manifest
#                    mirror .dotsteward/manifest.x86_64-linux.json without
#                    components; its skill layout is the catalog's: legacy
#                    root ~/.codex/skills, link root ~/.claude/skills with
#                    the target prefix ../../.agents/skills/, excluded
#                    subtree .system, Home Manager skill root .agents/skills
#   agents_store     a stand-in for the Nix store; the framework source with
#                    its skills/ lives in agents_store/framework-source
#   agents_gen       the generation built by make_generation
#
#   set_hm_root REL  sets [skills] hm_root (workstation.toml and manifest)
#   set_installer JSON
#                    sets [skills] installer to the argv list JSON
#   manifest_edit JQ_FILTER [JQ_OPTION...]
#                    rewrites the manifest mirror with a jq filter
#   add_component NAME METHOD INSTALL_JSON [PROFILES_JSON]
#                    enables NAME and appends it to the manifest
#   add_hook LIST COMPONENT NAME [PROFILES_JSON]
#                    a hook script (read from standard input) of LIST:
#                    agents_install, agents_migrate, agents_post (manifest
#                    "hooks") or agents (manifest "checks.agents"); written
#                    to components/COMPONENT/NAME.sh of the instance
#   lock_set PATH JSON
#                    sets the dotted PATH of versions.lock.json
#   pin_download PATH FILE URL VERSION
#                    serves FILE at URL through the curl stub and writes
#                    { minimum_version, url, size, sha256 } at PATH
#   make_skill DIR NAME
#                    a symlink-free skill: SKILL.md (frontmatter NAME),
#                    references/guide.md, scripts/run.sh (0755),
#                    notes/private.txt (0600, in a 0750 directory)
#   lock_add NAME [--directory DIR] [--legacy DIR] [--deployment D]
#            [--no-directory-digest] [--tree]
#                    vendors agent/skills/DIR (default NAME; make_skill, or
#                    ds_fixture_skill_tree with --tree) unless it exists and
#                    appends a lock entry with its digests
#   lock_edit JQ_FILTER [JQ_OPTION...]
#                    rewrites the skills lock (expected_skill_count follows
#                    the number of entries)
#   vendored NAME    the vendored directory of a lock entry
#   framework_skill NAME
#                    adds NAME to the framework source and the framework
#                    skills manifest (tools/gen-skills-manifest.sh) and lists
#                    it in the manifest's skills.framework
#   make_generation  builds agents_gen: home-path/share/dotsteward/
#                    manifest.json (a copy of the mirror), home-path/bin and
#                    home-files/<hm_root>/<framework skill> links into the
#                    framework source
#   activate_framework_skills
#                    links ~/<hm_root>/<skill> -> agents_gen/home-files/...
#                    for every framework skill, as Home Manager does
#   run_agents MODE [ARG...]
#                    dotsteward --instance <instance> agents MODE --profile
#                    workstation ARG... (standard input empty)
#   home_state       a listing of HOME (paths, types, modes, link texts and
#                    file digests) for byte-identity comparisons
#   temp_dirs        the dotsteward-* directories left in TMPDIR

agents_fw=$DS_TEST_ROOT/framework
agents_inst=$DS_TEST_ROOT/instance
agents_manifest=$agents_inst/.dotsteward/manifest.x86_64-linux.json
agents_lock=$agents_inst/agent/skills.lock.json
agents_store=$DS_TEST_ROOT/store
agents_gen=$DS_TEST_ROOT/generation
agents_fw_source=$agents_store/framework-source

mkdir -p "$agents_fw/modules/components" "$agents_inst/.dotsteward" "$agents_inst/components" \
  "$agents_inst/agent/skills" "$agents_fw_source/skills"
cp -R "$DS_REPO_ROOT/cli" "$DS_REPO_ROOT/schema" "$DS_REPO_ROOT/VERSION" "$agents_fw/"

_agents_hm_root=.agents/skills
_agents_installer=''

_write_config() {
  cat >"$agents_inst/workstation.toml" <<'EOF'
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
EOF
  {
    printf '\n[skills]\nhm_root = "%s"\n' "$_agents_hm_root"
    if [[ -n $_agents_installer ]]; then
      printf 'installer = %s\n' "$_agents_installer"
    fi
  } >>"$agents_inst/workstation.toml"
  local name
  for name in "${_agents_components[@]}"; do
    printf '\n[components.%s]\nenable = true\n' "$name" >>"$agents_inst/workstation.toml"
    if [[ -n ${_agents_component_profiles[$name]:-} ]]; then
      printf 'profiles = %s\n' "${_agents_component_profiles[$name]}" >>"$agents_inst/workstation.toml"
    fi
  done
}
_agents_components=()
declare -A _agents_component_profiles=()
_write_config

printf '{\n  "schema_version": "1.0"\n}\n' >"$agents_inst/versions.lock.json"
jq -n '{ schema_version: "1.0", expected_skill_count: 0, skills: [] }' >"$agents_lock"

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
  skill_layout: {
    legacy_roots: ["~/.codex/skills"],
    link_roots: { "~/.claude/skills": { component: "claude-code", target_prefix: "../../.agents/skills/" } },
    excluded_subtrees: [".system"]
  },
  skills: { hm_root: ".agents/skills", framework: [], home_managed: [], framework_manifest: null }
}' >"$agents_manifest"

manifest_edit() {
  local filter=$1 tmp
  shift
  tmp=$(mktemp "$DS_TEST_ROOT/manifest.XXXXXX")
  jq "$@" "$filter" "$agents_manifest" >"$tmp"
  mv -- "$tmp" "$agents_manifest"
}

set_hm_root() {
  _agents_hm_root=$1
  _write_config
  manifest_edit '.skills.hm_root = $root' --arg root "$1"
}

set_installer() {
  _agents_installer=$(jq -c . <<<"$1")
  _write_config
}

add_component() {
  local name=$1 method=$2 install=$3 profiles=${4:-null}
  _agents_components+=("$name")
  if [[ $profiles != null ]]; then
    _agents_component_profiles[$name]=$(jq -c . <<<"$profiles")
  fi
  _write_config
  manifest_edit '.components += [{
      name: $name,
      source: "instance",
      method: $method,
      profiles: $profiles,
      platforms: ["linux"],
      options: {},
      modes: ({ workstation: "adopt", fresh: "fresh" }
        | with_entries(select($profiles == null or (.key as $p | $profiles | index($p))))),
      supported_methods: { linux: [$method], darwin: [] },
      install: $install
    }]' \
    --arg name "$name" --arg method "$method" --argjson install "$install" \
    --argjson profiles "$profiles"
}

add_hook() {
  local list=$1 component=$2 name=$3 profiles=${4:-null} filter
  local script=$agents_inst/components/$component/$name.sh
  mkdir -p "$(dirname "$script")"
  {
    printf '#!%s\n' "$BASH"
    cat
  } >"$script"
  chmod 0755 "$script"
  if [[ $list == agents ]]; then
    filter='.checks.agents += [$hook]'
  else
    filter='.hooks[$list] += [$hook]'
  fi
  manifest_edit "$filter" --arg list "$list" --argjson hook "$(jq -cn \
    --arg component "$component" --arg name "$name" --argjson profiles "$profiles" \
    '{ component: $component, name: $name, phase: "main", profiles: $profiles,
       script: ("<instance>/components/" + $component + "/" + $name + ".sh") }')"
}

lock_set() {
  local path=$1 value=$2 tmp
  tmp=$(mktemp "$DS_TEST_ROOT/lock.XXXXXX")
  jq --indent 2 --arg path "$path" --argjson value "$value" \
    'setpath($path | split("."); $value)' "$agents_inst/versions.lock.json" >"$tmp"
  mv -- "$tmp" "$agents_inst/versions.lock.json"
}

pin_download() {
  local path=$1 file=$2 url=$3 version=$4 size sha
  ds_curl_serve "$url" "$file"
  size=$(stat -c %s -- "$file")
  sha=$(sha256sum -- "$file" | awk '{print $1}')
  lock_set "$path" "$(jq -n --arg v "$version" --arg u "$url" --argjson s "$size" --arg h "$sha" \
    '{ minimum_version: $v, url: $u, size: $s, sha256: $h }')"
}

make_skill() {
  local dir=$1 name=$2
  mkdir -p "$dir/references" "$dir/scripts" "$dir/notes"
  printf -- '---\nname: %s\ndescription: Synthetic skill for dotsteward agents tests.\n---\n\n# %s\n' \
    "$name" "$name" >"$dir/SKILL.md"
  printf '# Guide of %s\n' "$name" >"$dir/references/guide.md"
  printf '#!/bin/sh\necho %s\n' "$name" >"$dir/scripts/run.sh"
  printf 'private notes of %s\n' "$name" >"$dir/notes/private.txt"
  chmod 0644 "$dir/SKILL.md" "$dir/references/guide.md"
  chmod 0755 "$dir/scripts/run.sh"
  chmod 0600 "$dir/notes/private.txt"
  chmod 0750 "$dir/notes"
}

lock_edit() {
  local filter=$1 tmp
  shift
  tmp=$(mktemp "$DS_TEST_ROOT/skills-lock.XXXXXX")
  jq --indent 2 "$@" "$filter | .expected_skill_count = (.skills | length)" "$agents_lock" >"$tmp"
  mv -- "$tmp" "$agents_lock"
}

lock_add() {
  local name=$1 directory='' legacy='' deployment='' dir_digest=1 tree=0
  shift
  while (($#)); do
    case $1 in
      --directory) directory=$2 && shift 2 ;;
      --legacy) legacy=$2 && shift 2 ;;
      --deployment) deployment=$2 && shift 2 ;;
      --no-directory-digest) dir_digest=0 && shift ;;
      --tree) tree=1 && shift ;;
      *) ds_fail "lock_add: unknown option $1" ;;
    esac
  done
  [[ -n $directory ]] || directory=$name
  local source=$agents_inst/agent/skills/$directory
  if [[ ! -e $source ]]; then
    if ((tree)); then
      ds_fixture_skill_tree "$source" "$name"
    else
      make_skill "$source" "$name"
    fi
  fi
  local skill_sha dir_sha=''
  skill_sha=$(sha256sum -- "$source/SKILL.md" | awk '{print $1}')
  if ((dir_digest)); then
    dir_sha=$(bash -c 'source "$1/cli/lib/lib.sh"; directory_sha256 "$2"' _ "$DS_REPO_ROOT" "$source")
  fi
  lock_edit '.skills += [{ name: $name, directory: $directory }
      + (if $legacy == "" then {} else { legacy_directory: $legacy } end)
      + (if $deployment == "" then {} else { deployment: $deployment } end)
      + { skill_sha256: $skill }
      + (if $dir == "" then {} else { directory_sha256: $dir } end)]' \
    --arg name "$name" --arg directory "$directory" --arg legacy "$legacy" \
    --arg deployment "$deployment" --arg skill "$skill_sha" --arg dir "$dir_sha"
}

vendored() {
  printf '%s\n' "$agents_inst/agent/skills/$(jq -r --arg n "$1" 'first(.skills[] | select(.name == $n)) | .directory' "$agents_lock")"
}

framework_skill() {
  local name=$1 framework_manifest
  make_skill "$agents_fw_source/skills/$name" "$name"
  bash "$DS_REPO_ROOT/tools/gen-skills-manifest.sh" --root "$agents_fw_source" >/dev/null
  framework_manifest=$(<"$agents_fw_source/skills/manifest.json")
  manifest_edit '.skills.framework += [$name] | .skills.framework_manifest = $manifest' \
    --arg name "$name" --argjson manifest "$framework_manifest"
}

make_generation() {
  local name hm_root
  rm -rf -- "$agents_gen"
  mkdir -p "$agents_gen/home-path/share/dotsteward" "$agents_gen/home-path/bin"
  cp -- "$agents_manifest" "$agents_gen/home-path/share/dotsteward/manifest.json"
  hm_root=$(jq -r '.skills.hm_root' "$agents_manifest")
  mkdir -p "$agents_gen/home-files/$hm_root"
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    ln -s "$agents_fw_source/skills/$name" "$agents_gen/home-files/$hm_root/$name"
  done < <(jq -r '.skills.framework[]' "$agents_manifest")
}

activate_framework_skills() {
  local name hm_root
  hm_root=$(jq -r '.skills.hm_root' "$agents_manifest")
  mkdir -p "$HOME/$hm_root"
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    ln -s "$agents_gen/home-files/$hm_root/$name" "$HOME/$hm_root/$name"
  done < <(jq -r '.skills.framework[]' "$agents_manifest")
}

run_agents() {
  local mode=$1
  shift
  "$agents_fw/cli/dotsteward" --instance "$agents_inst" agents "$mode" --profile workstation "$@" </dev/null
}

home_state() {
  (
    cd "$HOME" || exit
    find . -mindepth 1 -printf '%p %y %m %l\n' | LC_ALL=C sort
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
  )
}

temp_dirs() {
  find "$TMPDIR" -mindepth 1 -maxdepth 1 -name 'dotsteward-*' ! -name 'dotsteward-assert.*' -print | LC_ALL=C sort
}
