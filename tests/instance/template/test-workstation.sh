# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# template/workstation.toml (SPEC 10.1, 4.1, 10.3): the schema 1 skeleton
# that `dotsteward init` fills. It carries the marker comment
# `# dotsteward:template` (init fills a directory with the marker in place),
# is valid for both configuration readers with the placeholder identity, and
# has init's default profiles and no component.
# shellcheck source=tests/instance/template/helpers.sh
source "$DS_REPO_ROOT/tests/instance/template/helpers.sh"

toml=$tpl/workstation.toml

# The marker: one line of its own.
assert_eq 1 "$(grep -c -x '# dotsteward:template' "$toml")" "marker lines"

# Valid for the command line reader: no validation message.
assert_eq '[]' "$(PYTHONPATH=$DS_REPO_ROOT/cli/python PYTHONDONTWRITEBYTECODE=1 \
  python3 -s -P -m dotsteward_cli.config --file "$toml" errors | jq -c .)" "configuration errors"

document=$(python3 -c 'import json, sys, tomllib; print(json.dumps(tomllib.load(open(sys.argv[1], "rb"))))' "$toml")
assert_eq '["identity","instance","nix","profiles","schema_version"]' "$(jq -c keys <<<"$document")" "tables"
assert_json - '.schema_version == 1' <<<"$document"
# The placeholder identity: valid, and obviously not a real user.
assert_json - '.identity == { username: "user" }' "identity placeholder" <<<"$document"
assert_json - '.instance == { name: "workstation", remote: "git@github.com:user/workstation.git", checkout: "~/workstation" }' \
  "instance placeholder" <<<"$document"
assert_json - '.nix.systems == ["x86_64-linux"] and .nix.allow_unfree == false' "nix" <<<"$document"
# init's default profiles: the first adopts, the second installs fresh.
assert_json - '.profiles == {
  names: ["workstation", "fresh"], default: "workstation", check: "workstation", bootstrap: "fresh",
  workstation: { mode: "adopt" }, fresh: { mode: "fresh" }
}' "profiles" <<<"$document"

# The Nix reader resolves it to the same configuration as the command line
# reader, with no component.
nix_resolved=$(inst_json "dsLib.config.resolve { catalog = builtins.attrNames dsLib.catalog; }
  (builtins.fromTOML (builtins.readFile (repoRoot + \"/template/workstation.toml\")))")
assert_json - '.components.order == ["shell", "herdr", "claude-code", "codex", "opencode-pi", "vscode"]
  and ([.components | to_entries[] | select(.key != "order") | .value.enable] | all(. == false))' \
  "no enabled component" <<<"$nix_resolved"
cli_resolved=$(PYTHONPATH=$DS_REPO_ROOT/cli/python PYTHONDONTWRITEBYTECODE=1 \
  python3 -s -P -m dotsteward_cli.config --file "$toml" resolve)
assert_eq "$(jq -S . <<<"$nix_resolved")" "$(jq -S . <<<"$cli_resolved")" "both readers agree"
