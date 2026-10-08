# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# Nix regular expressions are portable POSIX extended regular expressions:
# builtins.match and builtins.split use the C library's regcomp, and the
# macOS (BSD) one refuses what glibc accepts. Every literal regular
# expression passed to types.strMatching, builtins.match or builtins.split
# in the repository's Nix files has no empty alternative ("(|", "|)", "||",
# a leading or trailing "|") and no GNU-only escape (\w \W \s \S \d \D \b
# \B \< \> \` \').
# shellcheck source=tests/static/helpers.sh
source "$DS_REPO_ROOT/tests/static/helpers.sh"

# regex_portability_hits ROOT: "path:line: regex" for every non-portable
# literal regular expression of the Nix files under ROOT.
regex_portability_hits() {
  local root=$1
  (cd "$root" && find . -name '*.nix' -type f -not -path './.git/*' -print0 | LC_ALL=C sort -z |
    xargs -0 -r grep -nHoE '(strMatching|builtins\.match|builtins\.split) "([^"\\]|\\.)*"' || true) |
    python3 -I -c '
import re, sys
gnu = re.compile(r"\\\\[wWsSdDbB<>`'"'"']")
for line in sys.stdin:
    where, _, call = line.rstrip("\n").partition(" \"")
    regex = call[:-1]
    location = where.rsplit(":", 1)[0].removeprefix("./")
    empty = "(|" in regex or "|)" in regex or "||" in regex or regex.startswith("|") or regex.endswith("|")
    if empty or gnu.search(regex):
        print(f"{location}: {regex}")
'
}

# The real tree is portable.
assert_eq "" "$(regex_portability_hits "$DS_REPO_ROOT")" "non-portable Nix regular expressions"

# Every rejected form is found, in lib/ and in a component module.
fw=$DS_TEST_ROOT/fw
framework_copy "$fw"
mkdir -p "$fw/modules/components/example-term"
cat >"$fw/lib/zz-regex.nix" <<'EOF'
{ types }:
{
  a = types.strMatching "(~|)/.+";
  b = builtins.match "(|x)y" "y";
  c = builtins.split "a||b" "ab";
  d = types.strMatching "|x";
  e = builtins.match "\\w+" "x";
  f = builtins.split "\\s" "a b";
  g = builtins.match "(~)?/.+" "/x";
}
EOF
printf '{ x = builtins.match "x|" "x"; }\n' >"$fw/modules/components/example-term/zz.nix"
hits=$(regex_portability_hits "$fw")
for expected in 'lib/zz-regex.nix:3: (~|)/.+' 'lib/zz-regex.nix:4: (|x)y' 'lib/zz-regex.nix:5: a||b' \
  'lib/zz-regex.nix:6: |x' 'lib/zz-regex.nix:7: \\w+' 'lib/zz-regex.nix:8: \\s' \
  'modules/components/example-term/zz.nix:1: x|'; do
  grep -qxF -- "$expected" <<<"$hits" || ds_fail "not found: $expected (hits: $hits)"
done
# The portable spelling of an optional prefix is accepted.
! grep -qF 'zz-regex.nix:9:' <<<"$hits" || ds_fail "portable regex reported: $hits"
