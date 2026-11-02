# shellcheck shell=bash
# shellcheck disable=SC2016,SC2154,SC2164 # jq programs in single quotes; DS_* and craft_* variables come from the harness and helpers.sh; errexit stops a failed cd
# The seeds of the github-release-deb components: schema version 1, no
# flake input, and one pin desktop_packages.<name> whose URL is the asset
# <name>-<version>-linux-x86_64.deb of release v<version> of
# storytold/<name>, with its size and SHA-256. The framework's seed checks
# accept them, every lock path the components read is in their seeds, and
# the pins engine accepts their rules over a lock started from the seeds
# (and rejects a pin whose URL does not name its version).
# shellcheck source=tests/nix/components/github-release-deb/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/github-release-deb/helpers.sh"

names=(pdfcraft gridcraft wordcraft deckcraft craft-anything)

for name in "${names[@]}"; do
  seed=$DS_REPO_ROOT/modules/components/$name/seed.json
  [[ -f $seed ]] || ds_fail "missing modules/components/$name/seed.json"
  jq -e --arg n "$name" '.schema_version == 1 and .component == $n and .flake_inputs == {}
    and (.versions_lock | keys) == ["desktop_packages"]
    and (.versions_lock.desktop_packages | keys) == [$n]
    and (.versions_lock.desktop_packages[$n]
      | (keys == ["minimum_version", "sha256", "size", "url"])
        and (.minimum_version | test("^[0-9]+[.][0-9]+[.][0-9]+$"))
        and .url == ("https://github.com/storytold/" + $n + "/releases/download/v" + .minimum_version
          + "/" + $n + "-" + .minimum_version + "-linux-x86_64.deb")
        and (.size | type == "number" and . > 0)
        and (.sha256 | test("^[0-9a-f]{64}$")))' "$seed" >/dev/null ||
    ds_fail "$name: unexpected seed $(jq -c . "$seed")"

  # The fixture instance starts from the seed, as `dotsteward init` merges it.
  jq -e --slurpfile seed "$seed" '. as $lock | $seed[0].versions_lock
    | [paths(scalars)] | all(. as $path | ($lock | getpath($path)) == ($seed[0].versions_lock | getpath($path)))' \
    "$craft_fixture/versions.lock.json" >/dev/null || ds_fail "the fixture lock does not contain the $name seed"
done

# The framework's seed check accepts them.
cd "$DS_REPO_ROOT"
assert_exit 0 "$DS_REPO_ROOT/cli/dotsteward" static --sandbox --only seeds
assert_contains "$DS_STDOUT" "[dotsteward] static checks passed (framework): seeds"

# seed_lock_problems: the lock-path problems of the framework catalog
# (tests/static/seed-lock-paths.nix), compact JSON.
seed_lock_problems() {
  [[ -n ${DS_HOME_MANAGER:-} && -n ${nix_lib_store:-} ]] || nix_core_init
  local out=$DS_TEST_ROOT/seed-lock-paths.out err=$DS_TEST_ROOT/seed-lock-paths.err
  env -u NIX_REMOTE -u NIX_PATH \
    NIX_STORE_DIR="$nix_lib_store/store" \
    NIX_STATE_DIR="$nix_lib_store/state" \
    NIX_LOG_DIR="$nix_lib_store/log" \
    NIX_CONF_DIR="$nix_lib_store/etc" \
    NIX_LOCALSTATE_DIR="$nix_lib_store/state" \
    nix-instantiate --eval --strict --json --show-trace \
    --argstr nixpkgs "$DS_NIXPKGS" --argstr homeManager "$DS_HOME_MANAGER" --argstr repo "$DS_REPO_ROOT" \
    "$DS_REPO_ROOT/tests/static/seed-lock-paths.nix" >"$out" 2>"$err" ||
    ds_fail "lock-path evaluation failed: $(<"$err")"
  jq -c . "$out"
}
problems=$(seed_lock_problems)
for name in "${names[@]}"; do
  assert_eq '[]' "$(jq -c --arg n "$name/" 'map(select(startswith($n)))' <<<"$problems")" "lock paths of $name"
done

# The pins engine over the fixture instance (its lock holds the seeds): the
# rules of the committed manifest mirrors pass.
inst=$(instance_copy "$craft_fixture")
write_mirrors "instance { root = /. + \"$inst\"; }" "$inst"
git -C "$inst" init -q -b main
git -C "$inst" add -A
git -C "$inst" -c user.name=check -c user.email=check@example.invalid commit -q -m instance
assert_exit 0 "$DS_REPO_ROOT/cli/dotsteward" --instance "$inst" pins check
assert_not_contains "$DS_STDOUT$DS_STDERR" "Traceback"

# A pin whose URL names another release fails its rule.
lock=$inst/versions.lock.json
jq --indent 2 '.desktop_packages.deckcraft.url = "https://github.com/storytold/deckcraft/releases/latest/download/deckcraft-linux-x86_64.deb"' \
  "$lock" >"$lock.new"
mv -- "$lock.new" "$lock"
assert_exit 1 "$DS_REPO_ROOT/cli/dotsteward" --instance "$inst" pins check
assert_contains "$DS_STDERR" "desktop_packages.deckcraft.url"
