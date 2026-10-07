# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # Markdown with literal backticks is written on purpose
# The user documentation (SPEC 2.1, 6.2, 11.7).
#
# Lint of README.md and docs/**/*.md: the user documents exist; every file
# is printable ASCII without tabs or trailing whitespace and ends with one
# newline; it opens with its only H1 and never skips a heading level; every
# fenced block is closed and names a language; every relative link resolves
# inside the repository, an anchor to a heading of the target; every page
# below docs/ is linked from another document; every `dotsteward <command>`
# in a shell block or a code span names a command of cli/commands with an
# option that command documents in docs/cli.md; docs/cli.md has one section
# per command and docs/exit-codes.md one row; docs/workstation-toml.md names
# every key of schema/workstation.schema.json; every command summary starts
# with a capital letter.
#
# Generation: tools/gen-docs.sh writes docs/cli.md from the help of every
# command and docs/catalog.md plus docs/components/<name>.md from the
# catalog component directories; --check finds a stale, missing or extra
# generated file and ignores the line wrapping of help text, which differs
# between Python versions.
# shellcheck source=tests/static/helpers.sh
source "$DS_REPO_ROOT/tests/static/helpers.sh"

GEN=tools/gen-docs.sh

# docs_findings ROOT: one "path[:line]: problem" line per lint finding in
# the framework tree ROOT; empty when the documentation is clean.
docs_findings() {
  python3 -I - "$1" <<'PY'
import json
import os
import re
import sys

root = sys.argv[1]
findings = []


def finding(path, line, message):
    findings.append(f"{path}:{line}: {message}" if line else f"{path}: {message}")


REQUIRED = ["README.md"] + [
    f"docs/{name}.md"
    for name in (
        "architecture",
        "getting-started-ubuntu",
        "getting-started-macos",
        "concepts",
        "workstation-toml",
        "cli",
        "exit-codes",
        "catalog",
    )
]
LINK_SOURCES_EXTRA = ["CONTRIBUTING.md", "SECURITY.md"]
SHELL_LANGS = {"sh", "bash", "shell", "zsh", "console", "shell-session"}
FENCE = re.compile(r"^\s*(`{3,}|~{3,})\s*(.*)$")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
LINK = re.compile(r"!?\[(?:[^\]\\]|\\.)*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
CODE_SPAN = re.compile(r"(`+)(.+?)\1")
COMMAND = re.compile(
    r"(?:(?<![\w./:-])dotsteward|(?<![\w-])cli\.sh|(?<![\w-])cli/dotsteward)"
    r"(?:\s+--instance(?:=|\s+)\S+)?\s+([a-z][a-z0-9-]*)([^|;&)`]*)"
)
FLAG = re.compile(r"(?<![\w-])--[a-z][a-z0-9-]*")
GLOBAL_FLAGS = {"--instance", "--help"}


def rel(path):
    return os.path.relpath(path, root)


def slug(text):
    text = re.sub(r"`|\*\*|__", "", text).strip().lower()
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def parse(path):
    """Lines outside fences, fenced blocks and heading slugs of PATH."""
    with open(path, "rb") as handle:
        data = handle.read()
    text = data.decode("utf-8", errors="replace")
    lines = text.split("\n")
    doc = {"data": data, "lines": lines, "prose": [], "blocks": [], "slugs": set(), "h1": []}
    fence = None
    seen = {}
    for number, line in enumerate(lines[:-1] if text.endswith("\n") else lines, 1):
        if fence is None:
            match = FENCE.match(line)
            if match:
                fence = {"mark": match.group(1), "lang": match.group(2).strip().lower(), "start": number, "body": []}
                continue
            doc["prose"].append((number, line))
            heading = HEADING.match(line)
            if heading:
                base = slug(heading.group(2))
                count = seen.get(base, 0)
                seen[base] = count + 1
                doc["slugs"].add(base if count == 0 else f"{base}-{count}")
                doc.setdefault("headings", []).append((number, len(heading.group(1))))
                if len(heading.group(1)) == 1:
                    doc["h1"].append(number)
        else:
            stripped = line.strip()
            mark = fence["mark"]
            if stripped and set(stripped) == {mark[0]} and len(stripped) >= len(mark):
                doc["blocks"].append(fence)
                fence = None
            else:
                fence["body"].append((number, line))
    doc["open_fence"] = fence
    return doc


commands = sorted(
    name[:-3]
    for name in os.listdir(os.path.join(root, "cli/commands"))
    if name.endswith(".sh")
) if os.path.isdir(os.path.join(root, "cli/commands")) else []

md_files = []
for name in ["README.md"]:
    if os.path.isfile(os.path.join(root, name)):
        md_files.append(name)
for directory, dirs, files in os.walk(os.path.join(root, "docs")):
    dirs.sort()
    for name in sorted(files):
        if name.endswith(".md"):
            md_files.append(rel(os.path.join(directory, name)))

for name in REQUIRED:
    if not os.path.isfile(os.path.join(root, name)):
        finding(name, 0, "missing")

docs = {name: parse(os.path.join(root, name)) for name in md_files}
link_sources = list(md_files)
for name in LINK_SOURCES_EXTRA:
    if os.path.isfile(os.path.join(root, name)):
        link_sources.append(name)
components_dir = os.path.join(root, "modules/components")
if os.path.isdir(components_dir):
    for name in sorted(os.listdir(components_dir)):
        readme = f"modules/components/{name}/README.md"
        if os.path.isfile(os.path.join(root, readme)):
            link_sources.append(readme)

# Flags each command documents: every option word of its docs/cli.md section.
command_flags = {}
if "docs/cli.md" in docs:
    current = None
    for number, line in enumerate(docs["docs/cli.md"]["lines"], 1):
        match = re.match(r"^## `([a-z][a-z0-9-]*)`\s*$", line)
        if match:
            current = match.group(1)
            if current in command_flags:
                finding("docs/cli.md", number, f"second section for command {current}")
            command_flags[current] = set()
            continue
        if line.startswith("## "):
            current = None
        elif current:
            command_flags[current].update(FLAG.findall(line))
    for name in commands:
        if name not in command_flags:
            finding("docs/cli.md", 0, f"no section for command {name}")
    for name in sorted(set(command_flags) - set(commands)):
        finding("docs/cli.md", 0, f"section for unknown command {name}")

# The summaries `dotsteward --help` and the command table of docs/cli.md
# show read as one list: each starts with a capital letter, without a
# final full stop.
for name in commands:
    path = f"cli/commands/{name}.sh"
    with open(os.path.join(root, path)) as handle:
        summary = next((line[len("# summary: "):].strip() for line in handle if line.startswith("# summary: ")), "")
    if not summary:
        finding(path, 0, "no # summary: line")
    elif not summary[0].isupper() or summary.endswith("."):
        finding(path, 0, "the summary must start with a capital letter and end without a full stop")

if "docs/exit-codes.md" in docs:
    rows = {}
    for number, line in docs["docs/exit-codes.md"]["prose"]:
        match = re.match(r"^\|\s*`([a-z][a-z0-9-]*)(?:\s[^`]*)?`\s*\|", line)
        if match:
            rows.setdefault(match.group(1), []).append(number)
    for name in commands:
        if name not in rows:
            finding("docs/exit-codes.md", 0, f"no row for command {name}")
    for name in sorted(set(rows) - set(commands)):
        finding("docs/exit-codes.md", rows[name][0], f"row for unknown command {name}")


def check_command(path, number, text):
    for match in COMMAND.finditer(text):
        name, rest = match.group(1), match.group(2)
        if name not in commands:
            finding(path, number, f"unknown command dotsteward {name}")
            continue
        known = command_flags.get(name)
        if known is None:
            continue
        for flag in FLAG.findall(rest):
            if flag not in known and flag not in GLOBAL_FLAGS:
                finding(path, number, f"dotsteward {name} has no option {flag} in docs/cli.md")


linked = set()
for path in link_sources:
    doc = docs.get(path) or parse(os.path.join(root, path))
    base = os.path.dirname(path)
    for number, line in doc["prose"]:
        bare = CODE_SPAN.sub("", line)
        for target in LINK.findall(bare):
            if re.match(r"^[a-z][a-z0-9+.-]*:", target):
                continue
            file_part, _, anchor = target.partition("#")
            if file_part:
                resolved = os.path.normpath(os.path.join(base, file_part))
                if resolved.startswith(".."):
                    finding(path, number, f"link leaves the repository: {target}")
                    continue
                if not os.path.exists(os.path.join(root, resolved)):
                    finding(path, number, f"broken link: {target}")
                    continue
                if resolved != path:
                    linked.add(resolved)
            else:
                resolved = path
            if anchor and resolved.endswith(".md") and path in docs:
                target_doc = docs.get(resolved) or parse(os.path.join(root, resolved))
                if anchor not in target_doc["slugs"]:
                    finding(path, number, f"unknown anchor: {target}")

for path in md_files:
    doc = docs[path]
    data = doc["data"]
    if not data.endswith(b"\n") or data.endswith(b"\n\n"):
        finding(path, 0, "must end with exactly one newline")
    for number, line in enumerate(doc["lines"], 1):
        if any(ord(char) > 126 or (ord(char) < 32 and char != "\t") for char in line):
            finding(path, number, "non-ASCII or control character")
        if "\t" in line:
            finding(path, number, "tab character")
        if line != line.rstrip():
            finding(path, number, "trailing whitespace")
    if not doc["lines"] or not doc["lines"][0].startswith("# "):
        finding(path, 1, "must open with its H1 heading")
    for number in doc["h1"][1:]:
        finding(path, number, "second H1 heading")
    previous = 0
    for number, level in doc.get("headings", []):
        if previous and level > previous + 1:
            finding(path, number, f"heading level skips from {previous} to {level}")
        previous = level
    if doc["open_fence"]:
        finding(path, doc["open_fence"]["start"], "fenced block is never closed")
    for block in doc["blocks"] + ([doc["open_fence"]] if doc["open_fence"] else []):
        if not re.match(r"^[a-z0-9_+-]+$", block["lang"]):
            finding(path, block["start"], "fenced block names no language")
        if block["lang"] in SHELL_LANGS:
            for number, line in block["body"]:
                if block["lang"] in ("console", "shell-session"):
                    if not line.startswith("$ "):
                        continue
                    line = line[2:]
                check_command(path, number, line.split(" #")[0])
    for number, line in doc["prose"]:
        for _, span in CODE_SPAN.findall(line):
            check_command(path, number, span)
    if path.startswith("docs/") and path not in linked:
        finding(path, 0, "not linked from any other document")

schema_path = os.path.join(root, "schema/workstation.schema.json")
if "docs/workstation-toml.md" in docs and os.path.isfile(schema_path):
    with open(schema_path) as handle:
        schema = json.load(handle)
    defs = schema.get("$defs", {})
    keys = []

    def walk(node, path):
        if "$ref" in node and node["$ref"].startswith("#/$defs/"):
            node = defs[node["$ref"][len("#/$defs/"):]]
        properties = node.get("properties")
        extra = node.get("additionalProperties")
        named = isinstance(extra, dict) and extra.get("$ref", "").startswith("#/$defs/") and "properties" in defs.get(extra["$ref"][8:], {})
        if properties:
            for key, child in properties.items():
                walk(child, path + [key])
        if named:
            walk(extra, path + ["<name>"])
        if not properties and not named:
            keys.append(".".join(path))

    walk(schema, [])
    text = docs["docs/workstation-toml.md"]["data"].decode("utf-8", errors="replace")
    for key in keys:
        if f"`{key}`" not in text:
            finding("docs/workstation-toml.md", 0, f"does not document {key}")

print("\n".join(findings))
PY
}

# The real tree is clean and its generated documents are fresh.
assert_eq "" "$(docs_findings "$DS_REPO_ROOT")" "documentation lint of the framework tree"
assert_exit 0 "$DS_REPO_ROOT/$GEN" --check

fw=$DS_TEST_ROOT/fw
framework_copy "$fw"

# Help text wrapped differently (another Python version) is still fresh.
python3 -I - "$fw/docs/cli.md" <<'PY'
import re
import sys
path = sys.argv[1]
text = open(path).read()
new = re.sub(r"(\n  --[a-z-]+) +", r"\1\n                ", text, count=3)
assert new != text
open(path, "w").write(new)
PY
assert_exit 0 "$fw/$GEN" --check

# A changed component summary, a new command and a removed component each
# make the generated documents stale; writing them makes them fresh again,
# removes the document of the removed component and changes nothing more on
# a second run.
summary_line=$(awk 'NR > 1 && NF { print NR; exit }' "$fw/modules/components/herdr/README.md")
sed -i "${summary_line}s/.*/A replaced summary of the component./" "$fw/modules/components/herdr/README.md"
assert_exit 1 "$fw/$GEN" --check
assert_contains "$DS_STDERR" "docs/components/herdr.md"
assert_contains "$DS_STDERR" "docs/catalog.md"
assert_not_contains "$DS_STDERR" "docs/cli.md"

cat >"$fw/cli/commands/example-app.sh" <<'SH'
#!/usr/bin/env bash
# summary: Print an example line
printf 'Usage: dotsteward example-app [--alpha] [--beta NAME]\n'
SH
chmod +x "$fw/cli/commands/example-app.sh"
assert_exit 1 "$fw/$GEN" --check
assert_contains "$DS_STDERR" "docs/cli.md"

rm -r -- "$fw/modules/components/vscode"
assert_exit 1 "$fw/$GEN" --check
assert_contains "$DS_STDERR" "docs/components/vscode.md"

assert_exit 0 "$fw/$GEN"
assert_exit 0 "$fw/$GEN" --check
[[ ! -e $fw/docs/components/vscode.md ]] || ds_fail "the document of the removed component is still there"
assert_contains "$(<"$fw/docs/components/herdr.md")" "A replaced summary of the component."
assert_contains "$(<"$fw/docs/catalog.md")" "A replaced summary of the component."
assert_not_contains "$(<"$fw/docs/catalog.md")" "vscode"
cli_doc=$(<"$fw/docs/cli.md")
assert_contains "$cli_doc" '## `example-app`'
assert_contains "$cli_doc" "Print an example line"
assert_contains "$cli_doc" "Usage: dotsteward example-app [--alpha] [--beta NAME]"
before=$(cd "$fw/docs" && find . -type f -exec sha256sum {} + | LC_ALL=C sort)
assert_exit 0 "$fw/$GEN"
assert_eq "$before" "$(cd "$fw/docs" && find . -type f -exec sha256sum {} + | LC_ALL=C sort)" "a second run changes nothing"

# Every lint rule finds its defect.
lint=$DS_TEST_ROOT/lint
framework_copy "$lint"
cd "$lint" || exit 1
printf 'A caf\xc3\xa9 line.\n' >>docs/architecture.md
printf 'Trailing space. \n' >>docs/concepts.md
printf '\tIndented by a tab.\n' >>docs/concepts.md
{
  printf '\n# A second title\n'
  printf '\n#### Skipped levels\n'
  printf '\nSee [nothing](missing.md) and [no heading](cli.md#no-such-heading).\n'
  printf '\nOutside: [up](../../outside.md).\n'
  printf '\n```\nno language\n```\n'
  printf '\n```bash\ndotsteward frobnicate --now\n```\n'
  printf '\nRun `dotsteward rebuild --frobnicate` and `./.dotsteward/cli.sh gate --scope update`.\n'
  printf '\n```console\n$ dotsteward pins check --everything\noutput dotsteward bogus\n```\n'
  printf '\n```text\ndotsteward unknown-in-text\n```\n'
  printf '\n```bash\nnever closed\n'
} >>docs/getting-started-ubuntu.md
printf '# Orphan\n\nNo document links here.\n' >docs/orphan.md
printf 'No final newline.' >>docs/catalog.md
sed -i '/^| `gate`/d' docs/exit-codes.md
printf '| `example-app` | 0 | none |\n' >>docs/exit-codes.md
sed -i 's/`gate\.nix_cores`/gate nix cores/g' docs/workstation-toml.md
sed -i '/^## `sync`/,$d' docs/cli.md
sed -i 's/^# summary: Print/# summary: print/' cli/commands/version.sh
rm -- docs/getting-started-macos.md
findings=$(docs_findings "$lint")
cd "$DS_TEST_ROOT" || exit 1
lines=$(wc -l <"$DS_REPO_ROOT/docs/architecture.md")
assert_contains "$findings" "docs/architecture.md:$((lines + 1)): non-ASCII or control character"
assert_contains "$findings" "docs/concepts.md:$(($(wc -l <"$DS_REPO_ROOT/docs/concepts.md") + 1)): trailing whitespace"
assert_contains "$findings" ": tab character"
assert_contains "$findings" "docs/getting-started-ubuntu.md:"
for message in "second H1 heading" "heading level skips from 1 to 4" "broken link: missing.md" \
  "unknown anchor: cli.md#no-such-heading" "link leaves the repository: ../../outside.md" \
  "fenced block names no language" "unknown command dotsteward frobnicate" \
  "dotsteward rebuild has no option --frobnicate in docs/cli.md" \
  "dotsteward pins has no option --everything in docs/cli.md" "fenced block is never closed"; do
  assert_contains "$findings" "$message"
done
assert_not_contains "$findings" "--scope"
assert_not_contains "$findings" "bogus"
assert_not_contains "$findings" "unknown-in-text"
assert_contains "$findings" "docs/orphan.md: not linked from any other document"
assert_contains "$findings" "docs/catalog.md: must end with exactly one newline"
assert_contains "$findings" "docs/exit-codes.md: no row for command gate"
assert_contains "$findings" "row for unknown command example-app"
assert_contains "$findings" "docs/workstation-toml.md: does not document gate.nix_cores"
assert_contains "$findings" "docs/cli.md: no section for command sync"
assert_contains "$findings" "cli/commands/version.sh: the summary must start with a capital letter"
assert_contains "$findings" "docs/getting-started-macos.md: missing"
assert_contains "$findings" "broken link: docs/getting-started-macos.md"

# A document that opens without its title is found too.
printf 'Text before the title.\n\n# Title\n' >"$lint/docs/concepts.md"
assert_contains "$(docs_findings "$lint")" "docs/concepts.md:1: must open with its H1 heading"
