# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164 # DS_* variables and errexit (which stops a failed cd) come from tests/lib/harness.sh
# Framework code reads pins only through declared lock paths (SPEC 5.4): no
# URL or hash literal of a fixture lock (tests/**/fixtures/**/*.lock.json or
# *-lock.json; other fixture JSON, such as JSONC samples, is not a lock) or
# of a component seed (modules/components/*/seed.json) appears in the
# framework sources (cli/, engines/, lib/, modules/, nix/; data files such
# as JSON and Markdown excluded).
# shellcheck source=tests/static/helpers.sh
source "$DS_REPO_ROOT/tests/static/helpers.sh"

# pin_literals ROOT: the URL and hash literals of the locks and seeds,
# sorted and unique.
pin_literals() {
  local root=$1 file
  local -a files=()
  while IFS= read -r -d '' file; do
    files+=("$file")
  done < <(cd "$root" && find tests modules -path '*/fixtures/*' \( -name '*.lock.json' -o -name '*-lock.json' \) -type f -print0 2>/dev/null
    cd "$root" && find modules/components -mindepth 2 -maxdepth 2 -name seed.json -type f -print0 2>/dev/null)
  ((${#files[@]})) || return 0
  (cd "$root" && jq -r '.. | strings
      | select(test("^https?://") or test("^[0-9a-f]{40}$") or test("^[0-9a-f]{64}$")
        or test("^sha(1|256|512)-[A-Za-z0-9+/]+=*$"))' "${files[@]}") | LC_ALL=C sort -u
}

# pin_literal_hits ROOT: "path: literal #n" for every source file holding a
# literal (n is the literal's position in the sorted list, so the output
# never repeats a pin).
pin_literal_hits() {
  local root=$1 literal n=0 path
  local -a sources=()
  while IFS= read -r -d '' path; do
    sources+=("${path#./}")
  done < <(cd "$root" && find cli engines lib modules nix -type f ! -name '*.json' ! -name '*.md' \
    ! -name '*.pyc' -print0 2>/dev/null | LC_ALL=C sort -z)
  ((${#sources[@]})) || return 0
  while IFS= read -r literal; do
    n=$((n + 1))
    [[ -n $literal ]] || continue
    (cd "$root" && grep -lF -e "$literal" -- "${sources[@]}" || true) | while IFS= read -r path; do
      printf '%s: literal #%s\n' "$path" "$n"
    done
  done < <(pin_literals "$root")
}

# The extraction finds the literals of the shared lock fixture.
literals=$(pin_literals "$DS_REPO_ROOT")
[[ -n $literals ]] || ds_fail "no pin literal found in the fixture locks"

# The real tree is clean.
assert_eq "" "$(pin_literal_hits "$DS_REPO_ROOT")" "pin literals in framework sources"

# A literal copied into code, and a seed literal written into a component
# module, are both found.
fw=$DS_TEST_ROOT/fw
framework_copy "$fw"
first=$(head -n 1 <<<"$literals")
printf '# shellcheck shell=bash\npinned=%s\n' "$first" >"$fw/cli/lib/zz-pinned.sh"
mkdir -p "$fw/modules/components/example-term"
seed_url=https://downloads.example.invalid/example-term/v0.9.0/example-term.tar.gz
jq -n --arg url "$seed_url" '{schema_version: 1, component: "example-term", flake_inputs: {},
  versions_lock: {agent_tools: {"example-term": {url: $url}}}}' >"$fw/modules/components/example-term/seed.json"
printf '{ ... }: { url = "%s"; }\n' "$seed_url" >"$fw/modules/components/example-term/default.nix"
hits=$(pin_literal_hits "$fw")
assert_contains "$hits" "cli/lib/zz-pinned.sh: literal #"
assert_contains "$hits" "modules/components/example-term/default.nix: literal #"
assert_not_contains "$hits" "seed.json"
