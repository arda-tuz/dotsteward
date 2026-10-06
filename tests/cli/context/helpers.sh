# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Helpers for the context and doctor tests (tests/cli/context). Not a test
# file.
#
# Sourcing it copies cli/, schema/ and VERSION of the framework under test to
# context_framework ($DS_TEST_ROOT/framework) with the six public catalog
# component directories, so the catalog is fixed whatever modules/ holds,
# and the copy has no source-info and no git checkout (rev and narHash are
# unknown).
#
#   context_fixtures          the fixture directory
#   context_framework         the framework copy
#   ds_cli ARG...             runs the dispatcher (cli/dotsteward) of the
#                             framework copy
#   runtime_system            the Nix system of the running machine
#                             (<machine>-<platform>, as the CLI computes it)
#   make_rich_instance DIR    copies the rich fixture instance to DIR and
#                             writes flake.lock (the github variant) and the
#                             .dotsteward mirrors of its systems
#                             (x86_64-linux, aarch64-darwin) and of the
#                             running system (see write_mirror)
#   make_minimal_instance DIR the minimal fixture instance (required keys
#                             only, nothing else)
#   write_mirror DIR [SYSTEM] writes DIR/.dotsteward/manifest.SYSTEM.json from
#                             fixtures/manifest.json with the resolved
#                             configuration of DIR and the framework version,
#                             as a current mirror would hold them, and
#                             DIR/.dotsteward/stage0.<platform>.env
#   write_state STATE         writes the state records the tests read:
#                             current/profile (fresh) and
#                             update/{validation,candidate}.json
#   context_json DIR          runs `dotsteward context --json` in DIR (the
#                             instance is discovered from there) and prints
#                             its standard output; fails the test on a
#                             non-zero exit or a non-empty standard error
#   validate_schema FILE      FILE is valid against schema/context.schema.json
#                             (python jsonschema, Draft 2020-12)
#   use_fake_nix              puts the nix stub first on PATH

context_fixtures=$DS_REPO_ROOT/tests/cli/context/fixtures
context_framework=$DS_TEST_ROOT/framework

_context_make_framework() {
  local name
  mkdir -p "$context_framework/modules/components"
  cp -R "$DS_REPO_ROOT/cli" "$DS_REPO_ROOT/schema" "$DS_REPO_ROOT/VERSION" "$context_framework/"
  for name in shell herdr claude-code codex opencode-pi vscode; do
    mkdir -p "$context_framework/modules/components/$name"
  done
}
_context_make_framework

ds_cli() {
  "$context_framework/cli/dotsteward" "$@"
}

runtime_system() {
  local machine
  machine=$(uname -m)
  case $machine in
    amd64) machine=x86_64 ;;
    arm64) machine=aarch64 ;;
  esac
  printf '%s-%s\n' "$machine" "${DOTSTEWARD_PLATFORM:-linux}"
}

make_rich_instance() {
  local dir=$1
  mkdir -p "$dir"
  cp -R "$context_fixtures/instance/." "$dir/"
  cp "$context_fixtures/locks/github.json" "$dir/flake.lock"
  write_mirror "$dir" x86_64-linux
  write_mirror "$dir" aarch64-darwin
  write_mirror "$dir"
}

make_minimal_instance() {
  local dir=$1
  mkdir -p "$dir"
  cp "$DS_REPO_ROOT/tests/nix/lib/fixtures/valid/minimal.toml" "$dir/workstation.toml"
}

write_mirror() {
  local dir=$1 system=${2:-} config version platform
  [[ -n $system ]] || system=$(runtime_system)
  platform=${system#*-}
  config=$(PYTHONPATH=$context_framework/cli/python PYTHONDONTWRITEBYTECODE=1 \
    python3 -s -P -m dotsteward_cli.config --file "$dir/workstation.toml" resolve)
  version=$(<"$context_framework/VERSION")
  mkdir -p "$dir/.dotsteward"
  jq -S --indent 2 --argjson config "$config" --arg version "$version" --arg system "$system" \
    --arg platform "$platform" \
    '.config = $config | .framework.version = $version | .system = $system | .platform = $platform' \
    "$context_fixtures/manifest.json" >"$dir/.dotsteward/manifest.$system.json"
  printf 'DS_STAGE0_SCHEMA_VERSION=1\n' >"$dir/.dotsteward/stage0.$platform.env"
}

write_state() {
  local state=$1
  mkdir -p "$state/current" "$state/update"
  printf 'fresh\n' >"$state/current/profile"
  cat >"$state/update/validation.json" <<'EOF'
{"schema_version":"1.1","result":"passed","tree_oid":"0123456789abcdef0123456789abcdef01234567","scope":"maintain","validated_at":"2026-01-01T00:00:00Z","total_seconds":49}
EOF
  cat >"$state/update/candidate.json" <<'EOF'
{"schema_version":"1.1","base_oid":"0123456789abcdef0123456789abcdef01234567","scope":"maintain"}
EOF
}

context_json() {
  local dir=$1 out_file=$DS_TEST_ROOT/context.out err_file=$DS_TEST_ROOT/context.err status=0
  (cd "$dir" && ds_cli context --json) >"$out_file" 2>"$err_file" || status=$?
  ((status == 0)) || ds_fail "dotsteward context --json in $dir exited $status: $(<"$err_file")"
  [[ ! -s $err_file ]] || ds_fail "dotsteward context --json in $dir wrote to stderr: $(<"$err_file")"
  cat "$out_file"
}

_context_jsonschema_python() {
  if [[ -n ${DS_JSONSCHEMA_PYTHON:-} ]]; then
    printf '%s\n' "$DS_JSONSCHEMA_PYTHON"
    return 0
  fi
  # shellcheck source=tests/nix/lib/helpers.sh
  source "$DS_REPO_ROOT/tests/nix/lib/helpers.sh"
  nix_lib_jsonschema_python
}

validate_schema() {
  local file=$1 python
  python=$(_context_jsonschema_python)
  "$python" - "$DS_REPO_ROOT/schema/context.schema.json" "$file" <<'EOF' || ds_fail "$file is not valid against the context schema"
import json, sys
import jsonschema
schema = json.load(open(sys.argv[1]))
jsonschema.Draft202012Validator.check_schema(schema)
errors = sorted(jsonschema.Draft202012Validator(schema).iter_errors(json.load(open(sys.argv[2]))), key=str)
for error in errors:
    print(f"{list(error.absolute_path)}: {error.message}", file=sys.stderr)
sys.exit(1 if errors else 0)
EOF
}

use_fake_nix() {
  ds_use_stubs nix
}
