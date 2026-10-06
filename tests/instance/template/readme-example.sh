# shellcheck shell=bash
# Writes the example instance static script of template/tests/README.md (its
# fenced block without a language) to OUT, executable, so the tests and
# checks.template-static run the documented example as it is written.
#
# Usage: bash readme-example.sh README OUT
set -Eeuo pipefail

(($# == 2)) || {
  printf 'usage: readme-example.sh README OUT\n' >&2
  exit 2
}
awk '
  fence && /^```/ { if (capture) exit; fence = 0; next }
  !fence && /^```/ { fence = 1; capture = ($0 == "```"); found = found || capture; next }
  capture { print }
  END { if (!found) exit 1 }
' "$1" >"$2" || {
  printf 'readme-example.sh: %s has no fenced block without a language\n' "$1" >&2
  exit 1
}
[[ -s $2 ]] || {
  printf 'readme-example.sh: the example of %s is empty\n' "$1" >&2
  exit 1
}
chmod 0755 "$2"
