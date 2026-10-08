# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# Nix regular expressions are portable POSIX extended regular expressions.
# builtins.match and builtins.split compile them with the C++ standard
# library's std::regex (extended grammar): libstdc++ on Linux, libc++ on
# macOS. libc++ refuses what libstdc++ accepts: an empty alternative or
# group ("(|", "|)", "||", "()", a leading or trailing "|") and a quantifier
# right after a quantifier ("+?", "*{2}"). A backslash before anything but
# an ERE special character (\w, \s, \-, \/, a back-reference) is undefined
# in POSIX, so it is refused here too.
# Checked for every regular expression the framework hands to Nix:
#   - the "..." literal after strMatching, match or split (builtins.match
#     and the inherited match alike) in the repository's Nix files;
#   - the "..." literal bound to a name ending in Pattern or pattern there;
#   - every "pattern" of schema/*.json, as lib/config.nix matches it:
#     wrapped in .*( ).* (an empty pattern is an empty group).
# Nix string escapes are decoded first, so the checked text is the regular
# expression Nix compiles.
# shellcheck source=tests/static/helpers.sh
source "$DS_REPO_ROOT/tests/static/helpers.sh"

# regex_portability_hits ROOT: "location: regex: problem" for every
# non-portable regular expression of the Nix and schema files under ROOT.
regex_portability_hits() {
  python3 -I - "$1" <<'PY'
import json, pathlib, re, sys

root = pathlib.Path(sys.argv[1])
# ERE special characters: the only ones a backslash may precede.
SPECIAL = set("^.*[]$\\()|+?{}")
NIX_LITERAL = re.compile(
    r"""(?<![A-Za-z0-9_'-])(?:(?:match|split|strMatching)\s+|[A-Za-z_][A-Za-z0-9_'-]*[Pp]attern\s*=\s*)"((?:[^"\\]|\\.)*)\"""",
    re.S,
)
NIX_ESCAPES = {"n": "\n", "r": "\r", "t": "\t"}


def nix_unescape(text):
    return re.sub(r"\\(.)", lambda m: NIX_ESCAPES.get(m.group(1), m.group(1)), text, flags=re.S)


def bracket_end(regex, i):
    """The index after the bracket expression that starts at regex[i]."""
    j = i + 1
    if regex[j:j + 1] == "^":
        j += 1
    if regex[j:j + 1] == "]":
        j += 1
    while j < len(regex) and regex[j] != "]":
        if regex[j] == "[" and regex[j + 1:j + 2] in (":", ".", "="):
            end = regex.find(regex[j + 1] + "]", j + 2)
            j = len(regex) if end < 0 else end + 2
        else:
            j += 1
    return j + 1


def problems(regex):
    found = []
    # last: "start" (of the expression, a group or an alternative), "atom"
    # or "quantifier"; a ")" outside every group is an ordinary character.
    last, depth, i = "start", 0, 0
    while i < len(regex):
        char = regex[i]
        if char == "\\":
            if i + 1 == len(regex):
                found.append("trailing backslash")
                break
            if regex[i + 1] not in SPECIAL:
                found.append("escape \\" + regex[i + 1])
            last, i = "atom", i + 2
        elif char == "[":
            i = bracket_end(regex, i)
            if i > len(regex):
                found.append("unterminated bracket expression")
                break
            last = "atom"
        elif char in "*+?" or (char == "{" and last != "start"):
            if last == "quantifier":
                found.append("quantifier after a quantifier")
            if char == "{":
                close = regex.find("}", i)
                i = len(regex) if close < 0 else close
            last, i = "quantifier", i + 1
        elif char in "|)" and (char == "|" or depth > 0):
            if last == "start":
                found.append("empty alternative or group")
            depth -= char == ")"
            last, i = ("start" if char == "|" else "atom"), i + 1
        elif char == "(":
            depth, last, i = depth + 1, "start", i + 1
        else:
            last, i = "atom", i + 1
    if last == "start" and "empty alternative or group" not in found:
        found.append("empty alternative or group")
    return found


def report(location, regex):
    for problem in problems(regex):
        print(f"{location}: {regex}: {problem}")


for path in sorted(p for p in root.rglob("*.nix") if ".git" not in p.relative_to(root).parts):
    text = path.read_text(encoding="utf-8")
    for m in NIX_LITERAL.finditer(text):
        line = text.count("\n", 0, m.start(1)) + 1
        report(f"{path.relative_to(root)}:{line}", nix_unescape(m.group(1)))


def patterns(node, where):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "pattern" and isinstance(value, str):
                yield where + "/pattern", value
            else:
                yield from patterns(value, f"{where}/{key}")
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from patterns(value, f"{where}/{index}")


for path in sorted((root / "schema").glob("*.json")):
    for where, pattern in patterns(json.loads(path.read_text(encoding="utf-8")), ""):
        report(f"{path.relative_to(root)}#{where}", f".*({pattern}).*")
PY
}

# The real tree is portable.
assert_eq "" "$(regex_portability_hits "$DS_REPO_ROOT")" "non-portable regular expressions"

# Every rejected form is found: in lib/, in a component module, bound to a
# *Pattern name and in a schema.
fw=$DS_TEST_ROOT/fw
framework_copy "$fw"
mkdir -p "$fw/modules/components/example-term"
cat >"$fw/lib/zz-regex.nix" <<'EOF'
{ types, lib }:
let
  inherit (builtins) match split;
  hostPattern = "(~|)/.+";
in
{
  a = types.strMatching "(|x)y";
  b = builtins.match "a||b" "ab";
  c = split "x|" "x";
  d = match "|x" "x";
  e = builtins.match "a()b" "ab";
  f = builtins.match "\\w+" "x";
  g = builtins.split "\\s" "a b";
  h = match "a\\-b" "a-b";
  i = match "\\." ".";
  j = match "[|(]x" "x";
  k = match "[\\w]" "w";
  l = match "(~)?/.+|~/.+" "/x";
  m = lib.splitString "||" "a||b";
  n = match "a+?" "a";
  o = match "a{2}*" "aa";
}
EOF
printf '{ x = builtins.match "[[:alpha:]|]+(a|)" "x"; }\n' >"$fw/modules/components/example-term/zz.nix"
jq '.properties.zz = {type: "string", pattern: "^(a|)$"} | .properties.zy = {type: "string", pattern: ""}' \
  "$fw/schema/workstation.schema.json" >"$fw/schema/zz.json"
hits=$(regex_portability_hits "$fw")
for expected in \
  'lib/zz-regex.nix:4: (~|)/.+: empty alternative or group' \
  'lib/zz-regex.nix:7: (|x)y: empty alternative or group' \
  'lib/zz-regex.nix:8: a||b: empty alternative or group' \
  'lib/zz-regex.nix:9: x|: empty alternative or group' \
  'lib/zz-regex.nix:10: |x: empty alternative or group' \
  'lib/zz-regex.nix:11: a()b: empty alternative or group' \
  'lib/zz-regex.nix:12: \w+: escape \w' \
  'lib/zz-regex.nix:13: \s: escape \s' \
  'lib/zz-regex.nix:14: a\-b: escape \-' \
  'lib/zz-regex.nix:20: a+?: quantifier after a quantifier' \
  'lib/zz-regex.nix:21: a{2}*: quantifier after a quantifier' \
  'modules/components/example-term/zz.nix:1: [[:alpha:]|]+(a|): empty alternative or group' \
  'schema/zz.json#/properties/zz/pattern: .*(^(a|)$).*: empty alternative or group' \
  'schema/zz.json#/properties/zy/pattern: .*().*: empty alternative or group'; do
  grep -qxF -- "$expected" <<<"$hits" || ds_fail "not found: $expected (hits: $hits)"
done
# Portable spellings are accepted: an escaped special character, | and (
# inside a bracket expression, a backslash inside a bracket expression, an
# optional group, and the regex-free lib.splitString.
for line in 15 16 17 18 19; do
  ! grep -qF "zz-regex.nix:$line:" <<<"$hits" || ds_fail "portable regex reported at line $line: $hits"
done
assert_eq 14 "$(grep -c . <<<"$hits")" "hit count ($hits)"
