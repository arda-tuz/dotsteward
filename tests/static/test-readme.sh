# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The front page (README.md): it opens with the purpose (developers move
# between computers; a coding agent pointed at the personal instance
# repository reproduces the whole setup), then "How it works" names the
# public framework and the private instance, the agent skills, Nix and
# Home Manager, the validation gate, the pins from official sources and the
# local settings buffer, then a quick start installs the dotsteward-init
# skill for Claude Code and Codex. The pre-1.0 status line is gone.

readme=$DS_REPO_ROOT/README.md
[[ -f $readme ]] || ds_fail "missing README.md"

# The purpose: the first paragraph after the title.
purpose=$(awk 'NR > 1 && NF { found = 1 } found && !NF { exit } found { print }' "$readme" | tr '\n' ' ')
for text in "computers" "laptop" "desktop" "Claude Code" "Codex" "dotsteward repository" "agent"; do
  assert_contains "$purpose$(awk '/^## /{exit} {print}' "$readme" | tr '\n' ' ')" "$text" "the opening of README.md"
done
[[ $(awk '/^## / { print; exit }' "$readme") == "## How it works" ]] ||
  ds_fail "the first section of README.md is not How it works"

# section HEADING: the lines of the level-2 section HEADING.
section() {
  awk -v heading="## $1" '/^## / { inside = ($0 == heading) } inside { print }' "$readme"
}
how=$(section "How it works")
for text in "public" "private" "instance" "dotsteward-init" "dotsteward-maintain" "dotsteward-update" \
  "dotsteward-contribute" "Nix" "Home Manager" "gate" "official" "versions.lock.json" "settings buffer"; do
  assert_contains "$how" "$text" "How it works"
done

quick=$(section "Quick start")
[[ -n $quick ]] || ds_fail "README.md has no Quick start section"
for text in "claude plugin marketplace add https://github.com/arda-tuz/dotsteward.git" \
  "claude plugin install dotsteward@dotsteward" \
  "codex plugin marketplace add https://github.com/arda-tuz/dotsteward.git" \
  "codex plugin add dotsteward@dotsteward" "docs/getting-started-ubuntu.md"; do
  assert_contains "$quick" "$text" "Quick start"
done

assert_not_contains "$(<"$readme")" "under development" "README.md still calls the framework pre-release"
