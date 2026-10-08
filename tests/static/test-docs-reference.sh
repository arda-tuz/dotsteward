# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # sed scripts remove Markdown code spans with literal backticks
# The contributor and reference documentation. tests/static/test-docs.sh lints
# every page; this file checks that each page keeps up with the tree it
# describes:
#
# - CONTRIBUTING.md, SECURITY.md and the reference pages exist, and the two
#   root files link the pages a contributor and a reporter need;
# - docs/component-contract.md names every option of the component contract
#   (lib/contract.nix, evaluated) by its full path in option-doc notation
#   (checks.e2e.*.name, settingsTargets.<name>.path); a field of a list or
#   attribute-set record may also be named by its field name alone;
# - docs/pins-engine.md names every pin rule kind and latest adapter;
# - docs/settings-buffer.md names every `settings` command of docs/cli.md;
# - docs/contribute.md names every step of cli/commands/contribute.sh;
# - docs/skills.md names every framework and plugin skill, and
#   docs/overlays.md quotes the precedence sentence of the skills;
# - docs/privacy.md names every option of `scan` and every key of
#   privacy/policy.toml (a table key as <table>.<key>);
# - docs/update-policy.md names every key of the template lock's policy;
# - docs/writing-components.md names every file all catalog components have;
# - docs/testing.md names every suite directory below tests/ and every
#   assertion of tests/lib/assert.sh.
# shellcheck source=tests/static/helpers.sh
source "$DS_REPO_ROOT/tests/static/helpers.sh"
# shellcheck source=tests/nix/lib/helpers.sh
source "$DS_REPO_ROOT/tests/nix/lib/helpers.sh"

# The evaluated contract: option names (Nix option-doc notation, "*" for a
# list element and "<name>" for an attribute), rule kinds and adapters.
contract=$DS_TEST_ROOT/contract.json
nix_lib_json '{
  options = map (o: o.name) (lib.optionAttrSetToDocList
    (lib.evalModules { modules = [ dsLib.contract.componentModule ]; }).options);
  inherit (dsLib.contract) ruleKinds latestAdapters;
}' >"$contract"
assert_json "$contract" '(.options | index("install.official-binary.versionRegex") != null)
  and (.ruleKinds | length) > 0 and (.latestAdapters | length) > 0'

# reference_findings ROOT: one "path: problem" line per finding in the
# framework tree ROOT, checked against the contract of $contract.
reference_findings() {
  python3 -I - "$1" "$contract" <<'PY'
import json
import os
import re
import sys

root, contract_path = sys.argv[1], sys.argv[2]
with open(contract_path) as handle:
    contract = json.load(handle)
findings = []
PRECEDENCE = (
    "On the gate, publish preconditions, decision ownership, secrets, force push "
    "and the local-only rule, this skill wins over any overlay."
)
PAGES = [
    "component-contract", "writing-components", "settings-buffer", "pins-engine",
    "update-policy", "skills", "overlays", "contribute", "privacy", "testing",
]


def read(path):
    full = os.path.join(root, path)
    if not os.path.isfile(full):
        findings.append(f"{path}: missing")
        return None
    with open(full, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def spans(text):
    """Every code span and fenced line of TEXT, as one set of strings."""
    found = set(re.findall(r"`([^`\n]+)`", text))
    for block in re.findall(r"^```[a-z0-9_+-]*\n(.*?)^```", text, flags=re.S | re.M):
        found.update(line.strip() for line in block.splitlines())
    return found


def require_spans(path, text, names, what):
    have = spans(text)
    for name in names:
        if name not in have:
            findings.append(f"{path}: does not name {what} `{name}`")


def require_words(path, text, prefix, names, what):
    for name in names:
        if not re.search(re.escape(f"{prefix}{name}") + r"(?![\w-])", text):
            findings.append(f"{path}: does not name {what} {prefix}{name}")


def require_links(path, text, targets):
    links = set(re.findall(r"\]\(\s*<?([^)#\s>]+)", text))
    for target in targets:
        if target not in links:
            findings.append(f"{path}: does not link {target}")


docs = {name: read(f"docs/{name}.md") for name in PAGES}
contributing = read("CONTRIBUTING.md")
security = read("SECURITY.md")
if contributing is not None:
    require_links("CONTRIBUTING.md", contributing, [
        f"docs/{name}.md" for name in ("testing", "writing-components", "contribute", "privacy")
    ] + ["SECURITY.md"])
if security is not None:
    require_links("SECURITY.md", security, ["docs/privacy.md"])

text = docs["component-contract"]
if text is not None:
    have = spans(text)
    for name in contract["options"]:
        parts = name.split(".")
        if "_module" in parts or name in have:
            continue
        if ("*" in parts or "<name>" in parts) and parts[-1] in have:
            continue
        findings.append(f"docs/component-contract.md: does not name option `{name}`")

text = docs["pins-engine"]
if text is not None:
    require_spans("docs/pins-engine.md", text, contract["ruleKinds"], "rule kind")
    require_spans("docs/pins-engine.md", text, contract["latestAdapters"], "latest adapter")

text = docs["settings-buffer"]
if text is not None:
    with open(os.path.join(root, "docs/cli.md")) as handle:
        commands = re.findall(r"^### `settings ([a-z-]+)`$", handle.read(), flags=re.M)
    if not commands:
        findings.append("docs/cli.md: no settings commands")
    require_words("docs/settings-buffer.md", text, "settings ", commands, "command")

text = docs["contribute"]
if text is not None:
    with open(os.path.join(root, "cli/commands/contribute.sh")) as handle:
        steps = re.search(r"^\s*(mode(?: \| [a-z-]+)+)\) ;;$", handle.read(), flags=re.M)
    if not steps:
        findings.append("cli/commands/contribute.sh: no step list")
    else:
        require_words("docs/contribute.md", text, "contribute ", steps.group(1).split(" | "), "step")

for page in ("skills", "overlays"):
    text = docs[page]
    if text is not None and PRECEDENCE not in " ".join(text.split()):
        findings.append(f"docs/{page}.md: does not quote the precedence sentence")
text = docs["skills"]
if text is not None:
    skills = sorted(
        name for base in ("skills", "plugins/dotsteward/skills")
        for name in os.listdir(os.path.join(root, base))
        if os.path.isdir(os.path.join(root, base, name))
    )
    require_spans("docs/skills.md", text, skills, "skill")

text = docs["privacy"]
if text is not None:
    with open(os.path.join(root, "docs/cli.md")) as handle:
        section = re.search(r"^## `scan`$(.*?)(?=^## )", handle.read(), flags=re.S | re.M)
    flags = sorted(set(re.findall(r"(?<![\w-])--[a-z][a-z-]*", section.group(1)))) if section else []
    if not flags:
        findings.append("docs/cli.md: no scan options")
    keys, table = [], ""
    with open(os.path.join(root, "privacy/policy.toml")) as handle:
        for line in handle:
            match = re.match(r"^\[([a-z0-9_]+)\]\s*$", line)
            if match:
                table = match.group(1)
                keys.append(table)
                continue
            match = re.match(r"^([a-z0-9_]+)\s*=", line)
            if match:
                keys.append(f"{table}.{match.group(1)}" if table else match.group(1))
    require_words("docs/privacy.md", text, "", flags, "scan option")
    require_spans("docs/privacy.md", text, keys, "policy key")

text = docs["update-policy"]
if text is not None:
    with open(os.path.join(root, "template/versions.lock.json")) as handle:
        policy = list(json.load(handle)["policy"])
    require_spans("docs/update-policy.md", text, policy, "policy key")

text = docs["writing-components"]
if text is not None:
    base = os.path.join(root, "modules/components")
    common = None
    for name in sorted(os.listdir(base)):
        files = set(os.listdir(os.path.join(base, name)))
        common = files if common is None else common & files
    require_spans("docs/writing-components.md", text, sorted(common or ()), "component file")

text = docs["testing"]
if text is not None:
    suites = sorted(
        name for name in os.listdir(os.path.join(root, "tests"))
        if os.path.isdir(os.path.join(root, "tests", name))
    )
    require_words("docs/testing.md", text, "tests/", suites, "suite")
    with open(os.path.join(root, "tests/lib/assert.sh")) as handle:
        asserts = re.findall(r"^(assert_[a-z_]+)\(\)", handle.read(), flags=re.M)
    require_spans("docs/testing.md", text, asserts, "assertion")

print("\n".join(findings))
PY
}

# The real tree documents everything.
assert_eq "" "$(reference_findings "$DS_REPO_ROOT")" "reference documentation of the framework tree"

# Each rule finds its defect in a copy.
fw=$DS_TEST_ROOT/fw
framework_copy "$fw"
cd "$fw" || exit 1
sed -i 's/`[a-z.-]*versionRegex`//g; s/`[A-Za-z.<>]*unsetEnv`//g' docs/component-contract.md
sed -i 's/`skills-lock-mirror`//g; s/`deb-url`//g' docs/pins-engine.md
sed -i 's/settings track-file//g' docs/settings-buffer.md
sed -i 's/contribute abort//g' docs/contribute.md
python3 -I - docs/overlays.md <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
open(path, "w").write(text.replace("wins over any", "wins over\nan"))
PY
sed -i 's/`dotsteward-init`//g' docs/skills.md
sed -i 's/--extra-terms//g; s/`private_ipv4`//g; s/`commits\.utc_only`//g' docs/privacy.md
sed -i 's/`native_application_updates`//g' docs/update-policy.md
sed -i 's/`maintenance\.md`//g' docs/writing-components.md
sed -i 's#tests/channels##g; s/`assert_calls`//g' docs/testing.md
sed -i 's#(docs/privacy\.md)#(docs/missing.md)#g' SECURITY.md
rm -- docs/skills.md
mkdir tests/example-suite
printf 'assert_example() {\n  :\n}\n' >>tests/lib/assert.sh
findings=$(reference_findings "$fw")
cd "$DS_TEST_ROOT" || exit 1
for message in \
  "docs/component-contract.md: does not name option \`install.official-binary.versionRegex\`" \
  "docs/component-contract.md: does not name option \`reloadHooks.<name>.unsetEnv\`" \
  "docs/pins-engine.md: does not name rule kind \`skills-lock-mirror\`" \
  "docs/pins-engine.md: does not name latest adapter \`deb-url\`" \
  "docs/settings-buffer.md: does not name command settings track-file" \
  "docs/contribute.md: does not name step contribute abort" \
  "docs/overlays.md: does not quote the precedence sentence" \
  "docs/skills.md: missing" \
  "docs/privacy.md: does not name scan option --extra-terms" \
  "docs/privacy.md: does not name policy key \`private_ipv4\`" \
  "docs/privacy.md: does not name policy key \`commits.utc_only\`" \
  "docs/update-policy.md: does not name policy key \`native_application_updates\`" \
  "docs/writing-components.md: does not name component file \`maintenance.md\`" \
  "docs/testing.md: does not name suite tests/channels" \
  "docs/testing.md: does not name suite tests/example-suite" \
  "docs/testing.md: does not name assertion \`assert_calls\`" \
  "docs/testing.md: does not name assertion \`assert_example\`" \
  "SECURITY.md: does not link docs/privacy.md"; do
  assert_contains "$findings" "$message"
done
# A command whose name begins another one's is still named.
! grep -qx 'docs/settings-buffer.md: does not name command settings track' <<<"$findings" ||
  ds_fail "settings track is reported although the page names it"
