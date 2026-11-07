# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # Nix expressions in single quotes
# The table that `skills track NAME@MARKETPLACE --all` adds to workstation.toml, as its own
# editor writes it (dotsteward_cli.skills.plugins), against a real evaluation of the
# instance: the component options are part of the manifest, so the mirror committed before
# is stale afterwards (the dotsteward-manifest check fails), and the mirrors evaluated from
# the new tree, which is what `dotsteward generate` writes and the answer commits, pass it;
# the evaluation accepts the table (every assertion of the component runs on it), also with
# machines for --here and next to an entry of the same marketplace that turns autoUpdate off.
# shellcheck source=tests/nix/components/claude-code/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/claude-code/helpers.sh"

nix_core_init

inst=$(cc_instance tracked 'method = "external"

[[components.claude-code.options.plugins]]
spec = "kept-plugin@quiet-market"
marketplace = "example-org/quiet-market"
autoUpdate = false')
cc_mirror "$inst"
assert_inst_eq '"dotsteward-manifest"' "($(cc_expr "$inst")).checks.x86_64-linux.dotsteward-manifest.name" \
  "fresh mirrors before the answer"

# add_table SPEC REPO [MACHINE]: what the answer writes.
add_table() {
  PYTHONPATH=$DS_REPO_ROOT/cli/python PYTHONDONTWRITEBYTECODE=1 python3 -s -P - "$inst/workstation.toml" "$@" <<'PY'
import sys
from dotsteward_cli import tomlfile
from dotsteward_cli.skills import plugins

path, spec, repo = sys.argv[1:4]
machine = sys.argv[4] if len(sys.argv) > 4 else None
text = open(path, encoding="utf-8").read()
entry = plugins.options_entry(tomlfile.loads(text), spec, repo, machine)
open(path, "w", encoding="utf-8").write(plugins.with_options_entry(text, entry))
PY
}

add_table shared-plugin@example-market example-org/example-market
add_table quiet-plugin@quiet-market example-org/quiet-market
assert_inst_fails "($(cc_expr "$inst")).checks.x86_64-linux.dotsteward-manifest.drvPath" \
  "dotsteward: .dotsteward/manifest.x86_64-linux.json is stale" "run \`dotsteward generate\`"
cc_mirror "$inst"
assert_inst_eq '"dotsteward-manifest"' "($(cc_expr "$inst")).checks.x86_64-linux.dotsteward-manifest.name" \
  "the mirrors of the new tree are current"
assert_cc_eq '[
  {"spec": "kept-plugin@quiet-market", "marketplace": "example-org/quiet-market", "autoUpdate": false},
  {"spec": "shared-plugin@example-market", "marketplace": "example-org/example-market"},
  {"spec": "quiet-plugin@quiet-market", "marketplace": "example-org/quiet-market", "autoUpdate": false}
]' "(ccEntry ($(cc_expr "$inst")) \"x86_64-linux\").options.plugins"
assert_cc_eq '["plugins", "skill-hooks"]' \
  "map (hook: hook.name) (ccManifest ($(cc_expr "$inst")) \"x86_64-linux\").hooks.agents_post"

# --here: machines names a machine of hosts/.
mkdir -p "$inst/hosts"
printf 'schema_version = 1\n' >"$inst/hosts/a.toml"
add_table here-plugin@example-market example-org/example-market a
cc_mirror "$inst"
assert_cc_eq '["a"]' "(lib.last (ccEntry ($(cc_expr "$inst")) \"x86_64-linux\").options.plugins).machines"
assert_inst_eq '"dotsteward-manifest"' "($(cc_expr "$inst")).checks.x86_64-linux.dotsteward-manifest.name"
